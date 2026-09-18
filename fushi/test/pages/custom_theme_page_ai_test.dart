// 自定义主题编辑页「让 AI 帮忙」区的行为守卫。
//
// AI 路径只打假 http.Client，不打真网；没配提供商时必须**一个请求都不发**；
// 拿到结果只进编辑页草稿（角色覆盖 + 名字 + 开关），主题列表在按「应用」前一条
// 都不写；「撤销 AI 改动」把草稿（含全局音频高亮色）整份拉回生成前。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show kCustomThemeDefaultSeed;
import 'package:fushi/src/pages/implementations/custom_theme_page.dart';
import 'package:fushi/utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_platform_services.dart';

class _RecordingAppModel extends AppModel {
  _RecordingAppModel() : super(testPlatformServices());

  final List<CustomThemeEntry> upserts = <CustomThemeEntry>[];
  final List<Color?> audioHighlightWrites = <Color?>[];

  @override
  List<CustomThemeEntry> get customThemes => const <CustomThemeEntry>[];

  @override
  CustomThemeEntry? customThemeById(String id) => null;

  @override
  CustomThemeEntry? get activeCustomThemeEntry => null;

  @override
  Future<void> upsertCustomTheme(CustomThemeEntry entry) async {
    upserts.add(entry);
  }

  @override
  Future<void> selectCustomTheme(String id) async {}

  @override
  Future<void> setAppThemeKey(String key) async {}

  @override
  Future<void> setAudioHighlightColor(Color? color) async {
    audioHighlightWrites.add(color);
  }

  @override
  Color? get audioHighlightColor => null;

  @override
  String get brightnessMode => 'light';

  @override
  bool get isDarkMode => false;

  @override
  bool get einkMode => false;

  @override
  Color? get systemPrimaryColor => null;
}

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

Widget _host(_RecordingAppModel appModel, Widget home) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: home,
      ),
    ),
  );
}

final Finder _verticalScrollable = find
    .byWidgetPredicate(
      (Widget w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .first;

Future<void> _pumpAndRunAi(
  WidgetTester tester,
  _RecordingAppModel appModel, {
  required AiProviderConfig? provider,
  required AiChatClient Function() aiClientFactory,
}) async {
  await tester.pumpWidget(
    _host(
      appModel,
      CustomThemePage(
        resolveAiProvider: () => provider,
        aiClientFactory: aiClientFactory,
      ),
    ),
  );
  await tester.pumpAndSettle();

  final Finder request =
      find.byKey(const ValueKey<String>('custom-theme-ai-request'));
  await tester.scrollUntilVisible(request, 120,
      scrollable: _verticalScrollable);
  await tester.pumpAndSettle();
  await tester.enterText(request, '暖色纸张，主题色深绿');
  await tester
      .tap(find.byKey(const ValueKey<String>('custom-theme-ai-generate')));
  await tester.pumpAndSettle();
}

Future<void> _tapApply(WidgetTester tester) async {
  final Finder apply = find.byIcon(Icons.check);
  await tester.scrollUntilVisible(apply, 200, scrollable: _verticalScrollable);
  await tester.pumpAndSettle();
  await tester.tap(apply);
  await tester.pumpAndSettle();
}

String _messageText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey<String>('custom-theme-ai-message')))
    .data!;

void main() {
  testWidgets('没配 AI 提供商时提示去设置，且一个请求都不发', (WidgetTester tester) async {
    int requests = 0;
    final _RecordingAppModel appModel = _RecordingAppModel();
    await _pumpAndRunAi(
      tester,
      appModel,
      provider: null,
      aiClientFactory: () => AiChatClient(
        client: MockClient((http.Request request) async {
          requests += 1;
          return _openAiReply('{}');
        }),
      ),
    );

    expect(requests, 0);
    expect(_messageText(tester), t.ai_assist_no_provider);
    expect(
      find.byKey(const ValueKey<String>('custom-theme-ai-undo')),
      findsNothing,
    );
    expect(appModel.upserts, isEmpty);
  });

  testWidgets('假 client 返回 JSON → 颜色 / 名字进草稿，应用后才写进列表', (
    WidgetTester tester,
  ) async {
    final _RecordingAppModel appModel = _RecordingAppModel();
    await _pumpAndRunAi(
      tester,
      appModel,
      provider: _usableProvider(),
      aiClientFactory: () => AiChatClient(
        client: MockClient(
          (http.Request request) async => _openAiReply(
            '{"explanation":"暖纸配深绿",'
            '"name":"暖纸",'
            '"colors":{"accent":"#2E7D32","readerBackground":"#faf6ef",'
            '"readerText":"#3b2f2f","surface":"#80fffbf5","bogus":"#000000"}}',
          ),
        ),
      ),
    );

    expect(_messageText(tester), t.theme_ai_applied);
    expect(find.text('暖纸配深绿'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('custom-theme-ai-undo')),
      findsOneWidget,
    );
    // 名字进了输入框；主题列表在按「应用」前一条都没写。
    expect(find.widgetWithText(TextField, '暖纸'), findsOneWidget);
    expect(appModel.upserts, isEmpty);
    // AI 没给音频高亮色：全局偏好保持原值（null），没有被清成别的。
    expect(appModel.audioHighlightWrites, <Color?>[null]);

    await _tapApply(tester);
    final CustomThemeEntry saved = appModel.upserts.single;
    expect(saved.name, '暖纸');
    expect(saved.seed, 0xFF2E7D32);
    expect(saved.primaryColor, 0xFF2E7D32, reason: 'AI 选的主题色钉死为 primary');
    expect(saved.bgColor, 0xFFFAF6EF);
    expect(saved.fontColor, 0xFF3B2F2F);
    expect(saved.surfaceColor, 0xFFFFFBF5, reason: '界面底色不允许透明度');
    expect(saved.linkColor, isNull, reason: '没给的角色继续跟随主题');
  });

  testWidgets('「撤销 AI 改动」把草稿拉回生成前', (WidgetTester tester) async {
    final _RecordingAppModel appModel = _RecordingAppModel();
    await _pumpAndRunAi(
      tester,
      appModel,
      provider: _usableProvider(),
      aiClientFactory: () => AiChatClient(
        client: MockClient(
          (http.Request request) async => _openAiReply(
            '{"colors":{"accent":"#2E7D32","audioHighlight":"#40ffeb3b"}}',
          ),
        ),
      ),
    );
    expect(appModel.audioHighlightWrites.last, const Color(0x40FFEB3B));

    await tester
        .tap(find.byKey(const ValueKey<String>('custom-theme-ai-undo')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('custom-theme-ai-undo')),
      findsNothing,
    );
    expect(appModel.audioHighlightWrites.last, isNull, reason: '音频高亮色也撤回');

    await _tapApply(tester);
    final CustomThemeEntry saved = appModel.upserts.single;
    expect(saved.seed, kCustomThemeDefaultSeed);
    expect(saved.primaryColor, kCustomThemeDefaultSeed);
    expect(saved.sentenceAudioHighlightColor, isNull);
  });

  testWidgets('AI 回复解析不出结构 → 提示空结果，草稿不动', (WidgetTester tester) async {
    final _RecordingAppModel appModel = _RecordingAppModel();
    await _pumpAndRunAi(
      tester,
      appModel,
      provider: _usableProvider(),
      aiClientFactory: () => AiChatClient(
        client: MockClient(
          (http.Request request) async => _openAiReply('I cannot do that.'),
        ),
      ),
    );
    expect(_messageText(tester), t.ai_assist_empty);
    expect(
      find.byKey(const ValueKey<String>('custom-theme-ai-undo')),
      findsNothing,
    );
    expect(appModel.audioHighlightWrites, isEmpty);
  });
}
