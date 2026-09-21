/// AI 提供商设置的三层契约。
///
/// 1. **持久化层**：编解码往返与逐条容错（坏一条只丢一条、id 撞车丢后来者、
///    删提供商后功能映射跟着清理）。
/// 2. **界面层**：设置区真的把用户输入写穿偏好，删一家时**同时**清掉指向它的
///    功能映射——映射悬空的表现是「设置里选着一家已经不存在的 AI」。
/// 3. **wire 形状**：三种协议的请求形状（路径 / 鉴权位置）与状态码→短码映射。
///    这一层是唯一能在不打真网的情况下守住协议分派的东西：形状错了在生产里的
///    表现只是「这家 AI 用不了」，没有任何测试会告诉你错在哪一段。
library;

import 'dart:convert';
import 'dart:io';

// drift 也导出 isNull/isNotNull（SQL 表达式），与 matcher 撞名，故只取所需。
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_feature.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart';

import '../helpers/test_platform_services.dart';

AiProviderConfig _config({
  String id = 'p1',
  String presetId = 'openai',
  String name = 'OpenAI',
  String baseUrl = 'https://api.openai.com/v1',
  String apiKey = 'sk-secret',
  String model = 'gpt-4o-mini',
  AiWireProtocol protocol = AiWireProtocol.openAiCompatible,
  AiReasoningEffort reasoningEffort = AiReasoningEffort.none,
  bool enabled = true,
  bool allowInsecureHttp = false,
}) => AiProviderConfig(
  id: id,
  presetId: presetId,
  name: name,
  baseUrl: Uri.parse(baseUrl),
  apiKey: apiKey,
  model: model,
  protocol: protocol,
  reasoningEffort: reasoningEffort,
  enabled: enabled,
  allowInsecureHttp: allowInsecureHttp,
);

void main() {
  // ---------------------------------------------------------------------------
  // 1. 持久化层
  // ---------------------------------------------------------------------------

  group('AiProviderConfig 编解码', () {
    test('往返保留全部字段（含 base64 遮蔽的 API Key）', () {
      final AiProviderConfig source = _config(
        presetId: 'anthropic',
        name: 'Claude',
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'sk-ant-xxx',
        model: 'claude-sonnet-5',
        protocol: AiWireProtocol.anthropicMessages,
        reasoningEffort: AiReasoningEffort.high,
      );
      final List<AiProviderConfig> back = decodeAiProviderConfigs(
        encodeAiProviderConfigs(<AiProviderConfig>[source]),
      );
      expect(back, hasLength(1));
      expect(back.single.id, source.id);
      expect(back.single.presetId, 'anthropic');
      expect(back.single.name, 'Claude');
      expect(back.single.baseUrl, Uri.parse('https://api.anthropic.com'));
      expect(back.single.apiKey, 'sk-ant-xxx');
      expect(back.single.model, 'claude-sonnet-5');
      expect(back.single.protocol, AiWireProtocol.anthropicMessages);
      expect(back.single.reasoningEffort, AiReasoningEffort.high);
      expect(back.single.enabled, isTrue);
    });

    test('API Key 不以明文出现在编码结果里', () {
      final String raw = encodeAiProviderConfigs(<AiProviderConfig>[
        _config(apiKey: 'sk-plaintext-marker'),
      ]);
      expect(raw, isNot(contains('sk-plaintext-marker')));
    });

    test('明文 HTTP：loopback 恒放行，外网必须显式勾选', () {
      // 判据只在构造器一处（委托 isSafeExternalProviderEndpoint）：本机推理服务
      // 跑在 http://localhost，不放行等于把 Ollama / LM Studio 挡在门外；而外网
      // 明文 HTTP 会把 API Key 裸奔发出去，必须用户显式勾选才准存。
      expect(
        () => _config(baseUrl: 'http://api.example.com/v1'),
        throwsArgumentError,
      );
      expect(
        _config(
          baseUrl: 'http://api.example.com/v1',
          allowInsecureHttp: true,
        ).baseUrl.scheme,
        'http',
      );

      final AiProviderConfig local = _config(
        id: 'local',
        presetId: 'ollama',
        baseUrl: 'http://localhost:11434/v1',
        apiKey: '',
        model: 'qwen3',
        allowInsecureHttp: true,
      );
      final List<AiProviderConfig> back = decodeAiProviderConfigs(
        encodeAiProviderConfigs(<AiProviderConfig>[local]),
      );
      expect(back.single.allowInsecureHttp, isTrue);
      // ollama 预设不要求 key，所以没填 key 也算「配全了」。
      expect(back.single.isUsable, isTrue);
    });

    test('坏一条只丢一条，不让整份清单消失', () {
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{
          'id': 'good',
          'presetId': 'openai',
          'name': 'ok',
          'baseUrl': 'https://a.example.com/v1',
          'model': 'm',
        },
        // 协议不合法（非 http/https）→ 构造器抛，逐条跳过。
        <String, Object?>{'id': 'bad-scheme', 'baseUrl': 'ftp://a.example.com'},
        // 空 id → 构造器抛。
        <String, Object?>{'id': '  ', 'baseUrl': 'https://b.example.com'},
        // 明文 HTTP 未放行 → 构造器抛。
        <String, Object?>{'id': 'plain', 'baseUrl': 'http://c.example.com'},
        'not-a-map',
        <String, Object?>{
          'id': 'good2',
          'presetId': 'openai',
          'name': 'ok2',
          'baseUrl': 'https://d.example.com/v1',
          'model': 'm',
        },
      ]);
      expect(
        decodeAiProviderConfigs(raw).map((AiProviderConfig c) => c.id),
        <String>['good', 'good2'],
      );
    });

    test('id 撞车丢后来者（先来的那条是用户先配的）', () {
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{
          'id': 'dup',
          'name': 'first',
          'baseUrl': 'https://a.example.com',
          'model': 'm',
        },
        <String, Object?>{
          'id': 'dup',
          'name': 'second',
          'baseUrl': 'https://b.example.com',
          'model': 'm',
        },
      ]);
      final List<AiProviderConfig> decoded = decodeAiProviderConfigs(raw);
      expect(decoded, hasLength(1));
      expect(decoded.single.name, 'first');
    });

    test('整串不是 JSON / 不是数组 → 空清单而不是抛', () {
      expect(decodeAiProviderConfigs('{{{'), isEmpty);
      expect(decodeAiProviderConfigs('{"a":1}'), isEmpty);
      expect(decodeAiProviderConfigs(null), isEmpty);
      expect(decodeAiProviderConfigs('   '), isEmpty);
    });

    test('isUsable：关掉 / 没模型 / 没 key 都不算配全', () {
      expect(_config().isUsable, isTrue);
      expect(_config(enabled: false).isUsable, isFalse);
      expect(_config(model: '  ').isUsable, isFalse);
      expect(_config(apiKey: '').isUsable, isFalse);
    });
  });

  group('AiFeatureAssignments', () {
    test('往返 + 未知 key 忽略', () {
      const AiFeatureAssignments source = AiFeatureAssignments(
        providerIdByFeature: <AiFeature, String>{
          AiFeature.galgameTextProcess: 'p1',
        },
      );
      final AiFeatureAssignments back = AiFeatureAssignments.fromJson(
        source.toJson(),
      );
      expect(back.providerIdFor(AiFeature.galgameTextProcess), 'p1');
      expect(
        AiFeatureAssignments.fromJson(
          '{"no_such_feature":"p1"}',
        ).providerIdByFeature,
        isEmpty,
      );
      expect(
        AiFeatureAssignments.fromJson('nonsense').providerIdByFeature,
        isEmpty,
      );
    });

    test('resolve：没指派 / 指向已删 / 指向没配全 → 一律 null，绝不静默换一家', () {
      final List<AiProviderConfig> providers = <AiProviderConfig>[
        _config(id: 'usable'),
        _config(id: 'broken', model: ''),
      ];
      const AiFeatureAssignments empty = AiFeatureAssignments();
      expect(empty.resolve(AiFeature.galgameTextProcess, providers), isNull);
      expect(
        empty
            .withAssignment(AiFeature.galgameTextProcess, 'gone')
            .resolve(AiFeature.galgameTextProcess, providers),
        isNull,
      );
      expect(
        empty
            .withAssignment(AiFeature.galgameTextProcess, 'broken')
            .resolve(AiFeature.galgameTextProcess, providers),
        isNull,
        reason: '指向一家没配全的提供商时必须退化成未指派，而不是拿它去发请求',
      );
      expect(
        empty
            .withAssignment(AiFeature.galgameTextProcess, 'usable')
            .resolve(AiFeature.galgameTextProcess, providers)
            ?.id,
        'usable',
      );
    });

    test('withoutProvider 只清掉指向那一家的映射', () {
      final AiFeatureAssignments assigned = const AiFeatureAssignments()
          .withAssignment(AiFeature.galgameTextProcess, 'p1');
      expect(
        assigned
            .withoutProvider('other')
            .providerIdFor(AiFeature.galgameTextProcess),
        'p1',
      );
      expect(
        assigned
            .withoutProvider('p1')
            .providerIdFor(AiFeature.galgameTextProcess),
        isNull,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 2. 界面层：写穿偏好
  // ---------------------------------------------------------------------------

  group('AiProviderSettingsSection 写穿契约', () {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();

    late Directory pathProviderDir;
    setUpAll(() {
      pathProviderDir = Directory.systemTemp.createTempSync('hibiki_ai_pp');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => pathProviderDir.path,
      );
    });
    tearDownAll(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (pathProviderDir.existsSync()) {
        pathProviderDir.deleteSync(recursive: true);
      }
    });

    late FushiDatabase db;
    late PreferencesRepository prefs;
    late Directory storeDir;
    late AppModel appModel;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      storeDir = Directory.systemTemp.createTempSync('hibiki_ai_settings');
      appModel = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(
          prefsRepo: prefs,
          databaseDirectory: storeDir,
        );
    });

    tearDown(() async {
      await db.close();
      if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
    });

    /// 区块从树上摘掉时 **ProviderScope 原位保留**：整棵树换掉会连 AppModel 与
    /// PreferencesRepository 一起 dispose，dispose-flush 的异步写就会撞上一个已
    /// 释放的 repo——那是 harness 假象，不是生产行为。
    Widget harness() => ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: const AiProviderSettingsSection(),
            ),
          ),
        ),
      ),
    );

    Future<void> pumpSection(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
    }

    Future<void> enter(WidgetTester tester, String key, String text) async {
      final Finder field = find.byKey(ValueKey<String>(key));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, text);
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      final Finder target = find.byKey(ValueKey<String>(key));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    testWidgets('选预设新增一家 → 填 key/模型 → 防抖后写穿偏好', (WidgetTester tester) async {
      await pumpSection(tester);
      expect(prefs.aiProviders, isEmpty);

      await tapKey(tester, 'ai-provider-add');
      expect(
        find.byKey(const ValueKey<String>('ai-provider-preset-picker')),
        findsOneWidget,
      );
      await tapKey(tester, 'ai-provider-preset-deepseek');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      // 预设一落地就已经是合法配置（地址 + 模型来自预设），只差 key。
      expect(prefs.aiProviders, hasLength(1));
      expect(prefs.aiProviders.single.presetId, 'deepseek');
      expect(prefs.aiProviders.single.isUsable, isFalse);

      await enter(tester, 'ai-provider-0-api-key', 'sk-deep');
      await enter(tester, 'ai-provider-0-model', 'deepseek-reasoner');
      // 防抖窗口（600ms）过去后才落盘。
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      final AiProviderConfig saved = prefs.aiProviders.single;
      expect(saved.apiKey, 'sk-deep');
      expect(saved.model, 'deepseek-reasoner');
      expect(saved.protocol, AiWireProtocol.openAiCompatible);
      expect(saved.isUsable, isTrue);
    });

    testWidgets('一条草稿打字到中间态：跳过它，不连累同列表的其它提供商', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
        _config(id: 'p2', name: 'Beta', baseUrl: 'https://api.deepseek.com/v1'),
      ]);
      await pumpSection(tester);

      // `htt` 不是合法地址：这条草稿本轮无效，落盘时被跳过（它仍留在界面上，
      // 不报错也不弹窗——用户只是还没打完）。
      await enter(tester, 'ai-provider-0-base-url', 'htt');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        prefs.aiProviders.map((AiProviderConfig c) => c.id),
        <String>['p2'],
        reason: '一条草稿无效不该把整份清单一起写没',
      );
      expect(
        find.byKey(const ValueKey<String>('ai-provider-0-base-url')),
        findsOneWidget,
        reason: '中间态必须能停在输入框里',
      );

      // 打完就回来，id 不变，因此指向它的功能映射也还对得上。
      await enter(
        tester,
        'ai-provider-0-base-url',
        'https://api.moonshot.cn/v1',
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(prefs.aiProviders.map((AiProviderConfig c) => c.id), <String>[
        'p1',
        'p2',
      ]);
      expect(
        prefs.aiProviders.first.baseUrl.toString(),
        'https://api.moonshot.cn/v1',
      );
    });

    testWidgets('功能下拉选中一家 → 立刻写穿映射偏好', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
      ]);
      await pumpSection(tester);

      expect(
        prefs.aiFeatureAssignments.providerIdFor(AiFeature.galgameTextProcess),
        isNull,
      );
      await tapKey(
        tester,
        'ai-feature-${AiFeature.galgameTextProcess.storageKey}-provider',
      );
      // 下拉展开后菜单项与按钮内的项同名，取最后一个（菜单里那个）。
      await tester.tap(find.text('Alpha').last);
      await tester.pumpAndSettle();

      expect(
        prefs.aiFeatureAssignments.providerIdFor(AiFeature.galgameTextProcess),
        'p1',
      );
    });

    testWidgets('删一家：提供商与指向它的功能映射一起消失', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[_config(id: 'p1')]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments().withAssignment(
          AiFeature.galgameTextProcess,
          'p1',
        ),
      );
      await pumpSection(tester);

      await tapKey(tester, 'ai-provider-0-delete');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(prefs.aiProviders, isEmpty);
      expect(
        prefs.aiFeatureAssignments.providerIdFor(AiFeature.galgameTextProcess),
        isNull,
        reason: '映射悬空的表现是设置里选着一家已经不存在的 AI',
      );
    });

    testWidgets('候选选择器：没拉过先拉，选中即同时改字段显示与落盘', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', model: 'gpt-4o-mini'),
      ]);
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => appModel),
          ],
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: SizedBox(
                width: 640,
                child: SingleChildScrollView(
                  child: AiProviderSettingsSection(
                    clientFactory: () => AiChatClient(
                      client: MockClient((http.Request request) async {
                        return http.Response(
                          jsonEncode(<String, Object?>{
                            'data': <Object?>[
                              <String, Object?>{'id': 'gpt-4o-mini'},
                              <String, Object?>{'id': 'o4-mini'},
                            ],
                          }),
                          200,
                          headers: <String, String>{
                            'content-type': 'application/json',
                          },
                        );
                      }),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 迁移面：老用户落盘的模型名必须原样回显在字段里（字段仍是自由文本，
      // 候选只是辅助输入；写不进去就等于升级后把人家的自定义模型名吞了）。
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey<String>('ai-provider-0-model')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        'gpt-4o-mini',
      );

      // BUG-2618：「模型」这个值只允许有一个输入控件。候选必须长在字段自己身上，
      // 不能是字段外面另起的一行下拉——那样两处显示会各说各话。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('ai-provider-0-model')),
          matching: find.byKey(
            const ValueKey<String>('ai-provider-0-model-picker'),
          ),
        ),
        findsOneWidget,
      );

      // 没点过「获取模型列表」也能挑：箭头自己先拉一次。
      await tapKey(tester, 'ai-provider-0-model-picker');
      await tester.tap(find.text('o4-mini').last);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(prefs.aiProviders.single.model, 'o4-mini');
      // 回归点（BUG-2618）：选完候选，用户正看着的那个输入框必须当场变成新值。
      // 此前字段吃 `initialValue`（只认第一次 build），选完纹丝不动，界面上两处
      // 显示着不同的模型名，而落盘的偏偏是用户没在看的那一个。
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey<String>('ai-provider-0-model')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        'o4-mini',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 3. wire 形状
  // ---------------------------------------------------------------------------

  group('AiChatClient wire 形状', () {
    late http.BaseRequest captured;
    late String capturedBody;

    AiChatClient clientReturning(Object? body, {int status = 200}) =>
        AiChatClient(
          client: MockClient((http.Request request) async {
            captured = request;
            capturedBody = request.body;
            return http.Response(
              jsonEncode(body),
              status,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        );

    test('OpenAI 兼容：POST {base}/chat/completions + Bearer', () async {
      final AiChatClient client = clientReturning(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'hello'},
          },
        ],
      });
      addTearDown(client.close);
      final String reply = await client.complete(
        provider: _config(),
        messages: <AiChatMessage>[const AiChatMessage.user('hi')],
      );
      expect(reply, 'hello');
      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(captured.headers['authorization'], 'Bearer sk-secret');
      expect(captured.headers.containsKey('x-api-key'), isFalse);
      // 未选推理档位时绝不发 reasoning_effort：大量兼容端点不认识它，
      // 无条件发会让本来能用的服务直接 400。
      expect(capturedBody, isNot(contains('reasoning_effort')));
    });

    test('OpenAI 兼容：显式选了推理档位才发 reasoning_effort', () async {
      final AiChatClient client = clientReturning(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'x'},
          },
        ],
      });
      addTearDown(client.close);
      await client.complete(
        provider: _config(reasoningEffort: AiReasoningEffort.medium),
        messages: <AiChatMessage>[const AiChatMessage.user('hi')],
      );
      expect(
        jsonDecode(capturedBody) as Map<String, Object?>,
        containsPair('reasoning_effort', 'medium'),
      );
    });

    test(
      'Anthropic：POST {base}/v1/messages + x-api-key + anthropic-version',
      () async {
        final AiChatClient client = clientReturning(<String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'claude says'},
          ],
        });
        addTearDown(client.close);
        final String reply = await client.complete(
          provider: _config(
            presetId: 'anthropic',
            baseUrl: 'https://api.anthropic.com',
            apiKey: 'sk-ant',
            model: 'claude-sonnet-5',
            protocol: AiWireProtocol.anthropicMessages,
          ),
          messages: <AiChatMessage>[
            const AiChatMessage.system('be brief'),
            const AiChatMessage.user('hi'),
          ],
        );
        expect(reply, 'claude says');
        expect(
          captured.url.toString(),
          'https://api.anthropic.com/v1/messages',
        );
        expect(captured.headers['x-api-key'], 'sk-ant');
        expect(captured.headers['anthropic-version'], '2023-06-01');
        expect(captured.headers.containsKey('authorization'), isFalse);
        // system 提到顶层，不留在 messages 数组里。
        final Map<String, Object?> payload =
            jsonDecode(capturedBody) as Map<String, Object?>;
        expect(payload['system'], 'be brief');
        expect((payload['messages']! as List<Object?>), hasLength(1));
      },
    );

    test('Gemini：key 走 query 参数，不进 header', () async {
      final AiChatClient client = clientReturning(<String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{
            'content': <String, Object?>{
              'parts': <Object?>[
                <String, Object?>{'text': 'gemini says'},
              ],
            },
          },
        ],
      });
      addTearDown(client.close);
      final String reply = await client.complete(
        provider: _config(
          presetId: 'gemini',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          apiKey: 'goog-key',
          model: 'gemini-2.5-flash',
          protocol: AiWireProtocol.geminiGenerateContent,
        ),
        messages: <AiChatMessage>[const AiChatMessage.user('hi')],
      );
      expect(reply, 'gemini says');
      expect(
        captured.url.path,
        '/v1beta/models/gemini-2.5-flash:generateContent',
      );
      expect(captured.url.queryParameters['key'], 'goog-key');
      expect(captured.headers.containsKey('authorization'), isFalse);
      expect(captured.headers.containsKey('x-api-key'), isFalse);
    });

    test('listModels 的端点按协议分派', () async {
      for (final (AiWireProtocol protocol, String base, String expectedPath)
          in <(AiWireProtocol, String, String)>[
            (
              AiWireProtocol.openAiCompatible,
              'https://api.openai.com/v1',
              '/v1/models',
            ),
            (
              AiWireProtocol.anthropicMessages,
              'https://api.anthropic.com',
              '/v1/models',
            ),
            (
              AiWireProtocol.geminiGenerateContent,
              'https://generativelanguage.googleapis.com/v1beta',
              '/v1beta/models',
            ),
          ]) {
        final AiChatClient client = clientReturning(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{'id': 'models/zzz'},
            <String, Object?>{'id': 'aaa'},
          ],
        });
        final List<String> models = await client.listModels(
          _config(baseUrl: base, protocol: protocol),
        );
        client.close();
        expect(captured.method, 'GET');
        expect(captured.url.path, expectedPath);
        // Gemini 回的 `models/` 前缀要剥掉，结果按名排序。
        expect(models, <String>['aaa', 'zzz']);
      }
    });

    test('状态码映射成脱敏短码，且绝不回显凭据', () async {
      Future<String> failureOf(int status) async {
        final AiChatClient client = clientReturning(<String, Object?>{
          'error': 'sk-secret leaked here',
        }, status: status);
        addTearDown(client.close);
        try {
          await client.listModels(_config());
          fail('status $status should have thrown');
        } on AiChatFailure catch (failure) {
          expect(failure.message, isNot(contains('sk-secret')));
          return failure.message;
        }
      }

      expect(await failureOf(401), 'unauthorized');
      expect(await failureOf(403), 'unauthorized');
      expect(await failureOf(429), 'rate_limited');
      expect(await failureOf(500), 'http_500');
    });

    test('没配全的提供商在发请求前就被挡下', () async {
      final AiChatClient client = clientReturning(<String, Object?>{});
      addTearDown(client.close);
      expect(
        () => client.complete(
          provider: _config(model: ''),
          messages: <AiChatMessage>[const AiChatMessage.user('hi')],
        ),
        throwsA(
          isA<AiChatFailure>().having(
            (AiChatFailure f) => f.message,
            'message',
            'provider_not_configured',
          ),
        ),
      );
    });

    test('短码→界面文案的映射不漏项', () {
      for (final String code in <String>[
        'unauthorized',
        'rate_limited',
        'network_error',
        'bad_response',
        'empty_response',
        'provider_not_configured',
        'http_503',
      ]) {
        final String text = aiFailureText(code);
        expect(text, isNotEmpty);
        expect(text, isNot(code), reason: '$code 必须映射到真实文案而不是原样透出');
      }
      expect(aiFailureText('http_503'), contains('503'));
    });
  });
}
