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
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_key_rotation.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isPrivateNetworkProviderHost;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial, FushiGlassTheme;
import 'package:fushi/src/utils/components/settings_shared.dart'
    show AdaptiveSettingsRow;
import 'package:fushi/src/settings/settings_destination.dart'
    show debugSettingsForceExpandAllSections;
import 'package:fushi/src/settings/settings_kit.dart' show SettingsModifiedRow;
import 'package:fushi/utils.dart' show t;

import '../helpers/test_platform_services.dart';
import '../helpers/glass_unwrap.dart';

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

    test('明文 HTTP：局域网地址与 localhost 同等放行（反馈 9_vP-OLetJ）', () {
      // 局域网里另一台电脑上的 Ollama / LM Studio 用户填的是 http://192.168.x.x，
      // 不需要也不应要求勾「允许明文 HTTP」；公网明文 HTTP 仍要显式勾选。
      for (final String url in <String>[
        'http://192.168.0.178:1234/v1',
        'http://10.0.0.5:11434/v1',
        'http://172.20.1.2:8000/v1',
        'http://169.254.10.10/v1',
        'http://nas.local:1234/v1',
        'http://[fd12:3456::1]:1234/v1',
        'http://[fe80::1]:1234/v1',
      ]) {
        expect(_config(baseUrl: url).baseUrl.scheme, 'http', reason: url);
      }
      for (final String url in <String>[
        'http://172.32.0.1/v1',
        'http://100.64.1.2/v1',
        'http://8.8.8.8/v1',
        'http://192.169.0.1/v1',
        'http://[2001:db8::1]/v1',
      ]) {
        expect(() => _config(baseUrl: url), throwsArgumentError, reason: url);
      }
      expect(isPrivateNetworkProviderHost('192.168.1.1'), isTrue);
      expect(isPrivateNetworkProviderHost('192.168.1'), isFalse);
      expect(isPrivateNetworkProviderHost('example.com'), isFalse);
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
      pathProviderDir = Directory.systemTemp.createTempSync('fushi_ai_pp');
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
      // 功能指派行收在默认折叠的分组里（2026-10-08 所有者：外层只放总配置）。
      // 写穿契约测试要直接够到那些行，强制展开；折叠本身另有测试覆盖。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      debugSettingsForceExpandAllSections = true;
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      storeDir = Directory.systemTemp.createTempSync('fushi_ai_settings');
      appModel = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(
          prefsRepo: prefs,
          databaseDirectory: storeDir,
        );
    });

    tearDown(() async {
      debugSettingsForceExpandAllSections = false;
      await db.close();
      if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
    });

    /// 区块从树上摘掉时 **ProviderScope 原位保留**：整棵树换掉会连 AppModel 与
    /// PreferencesRepository 一起 dispose，dispose-flush 的异步写就会撞上一个已
    /// 释放的 repo——那是 harness 假象，不是生产行为。
    Widget harness({
      AiChatClientFactory? clientFactory,
      double width = 640,
      double textScale = 1,
      bool apple = false,
    }) => ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          extensions: <ThemeExtension<dynamic>>[
            FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
          ],
        ),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: AiProviderSettingsSection(clientFactory: clientFactory),
            ),
          ),
        ),
      ),
    );

    Future<void> pumpSection(
      WidgetTester tester, {
      AiChatClientFactory? clientFactory,
      double width = 640,
      double textScale = 1,
      bool apple = false,
    }) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        harness(
          clientFactory: clientFactory,
          width: width,
          textScale: textScale,
          apple: apple,
        ),
      );
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

    /// 提供商列表是「每家一行 → 点进编辑页」：编辑字段 / 自检 / 删除都在编辑页上。
    Future<void> openEditor(WidgetTester tester, String providerId) =>
        tapKey(tester, 'ai-provider-$providerId');

    Future<void> closeEditor(WidgetTester tester) async {
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
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

    testWidgets('多 key：添加 / 停用 / 删除写穿偏好，冷却状态显示在框下', (
      WidgetTester tester,
    ) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', apiKey: 'sk-first-1111'),
      ]);
      // 冷却记录走的是生产装配点（loadFromDb 装的偏好表实现），不是测试替身。
      aiKeyHealthStore.update(
        aiKeyFingerprint('p1', 'sk-first-1111'),
        (_) => AiKeyHealth(
          cooldownUntil: DateTime.now().toUtc().add(const Duration(hours: 1)),
          failures: 1,
          reason: 'rate_limited',
        ),
      );
      expect(prefs.aiKeyHealth, hasLength(1));
      await pumpSection(tester);
      await openEditor(tester, 'p1');

      expect(find.textContaining(t.ai_error_rate_limited), findsOneWidget);

      await tapKey(tester, 'ai-provider-0-api-key-add');
      await enter(tester, 'ai-provider-0-api-key-1', 'sk-second-2222');
      await tapKey(tester, 'ai-provider-0-api-key-0-toggle');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(prefs.aiProviders.single.apiKeys, const <AiApiKey>[
        AiApiKey('sk-first-1111', enabled: false),
        AiApiKey('sk-second-2222'),
      ]);
      expect(prefs.aiProviders.single.apiKey, 'sk-second-2222');
      expect(
        find.text(t.ai_provider_api_key_disabled(tail: '1111')),
        findsOneWidget,
      );

      // 删掉第一把：第二把顶到第一位，输入框里显示的必须是它自己的值（不沿用
      // 被删那把的 initialValue）。
      await tapKey(tester, 'ai-provider-0-api-key-0-remove');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(prefs.aiProviders.single.apiKeys, const <AiApiKey>[
        AiApiKey('sk-second-2222'),
      ]);
      final EditableText first = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('ai-provider-0-api-key')),
          matching: find.byType(EditableText),
        ),
      );
      expect(first.controller.text, 'sk-second-2222');
      expect(
        find.byKey(const ValueKey<String>('ai-provider-0-api-key-1')),
        findsNothing,
      );
    });

    testWidgets('测试连接逐把真打：冷却中的 key 充值后通过即清冷却，框下状态随之恢复', (
      WidgetTester tester,
    ) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        AiProviderConfig(
          id: 'p1',
          presetId: 'openai',
          name: 'OpenAI',
          baseUrl: Uri.parse('https://api.openai.com/v1'),
          apiKeys: const <AiApiKey>[
            AiApiKey('sk-first-1111'),
            AiApiKey('sk-second-2222'),
          ],
          model: 'gpt-4o-mini',
        ),
      ]);
      // 第一把余额不足，已退避到几小时后；轮换顺序里它排不上号。
      aiKeyHealthStore.update(
        aiKeyFingerprint('p1', 'sk-first-1111'),
        (_) => AiKeyHealth(
          cooldownUntil: DateTime.now().toUtc().add(const Duration(hours: 6)),
          failures: 9,
          reason: 'quota_exhausted',
        ),
      );
      final List<String> sent = <String>[];
      await pumpSection(
        tester,
        clientFactory: () => AiChatClient(
          client: MockClient((http.Request request) async {
            sent.add(
              (request.headers['authorization'] ?? '').replaceFirst(
                'Bearer ',
                '',
              ),
            );
            return http.Response(
              jsonEncode(<String, Object?>{
                'choices': <Object?>[
                  <String, Object?>{
                    'message': <String, Object?>{'content': 'pong'},
                  },
                ],
              }),
              200,
            );
          }),
        ),
      );
      await openEditor(tester, 'p1');
      expect(find.textContaining(t.ai_error_quota_exhausted), findsOneWidget);

      // 用户充值后点「测试连接」：冷却中的那把也要真打一次。
      await tapKey(tester, 'ai-provider-0-test');
      await tester.pumpAndSettle();

      expect(sent, <String>['sk-first-1111', 'sk-second-2222']);
      expect(prefs.aiKeyHealth, isEmpty);
      expect(find.text(t.ai_provider_api_key_ok(tail: '1111')), findsOneWidget);
      expect(find.textContaining(t.ai_error_quota_exhausted), findsNothing);
    });

    testWidgets('每分钟请求上限：填数字写穿配置，清空即不限', (WidgetTester tester) async {
      await pumpSection(tester);
      await tapKey(tester, 'ai-provider-add');
      await tapKey(tester, 'ai-provider-preset-deepseek');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(prefs.aiProviders.single.requestsPerMinute, 0, reason: '默认不限');

      await enter(tester, 'ai-provider-0-rate-limit', '20');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(prefs.aiProviders.single.requestsPerMinute, 20);

      await enter(tester, 'ai-provider-0-rate-limit', '');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(prefs.aiProviders.single.requestsPerMinute, 0);
    });

    testWidgets('一条草稿打字到中间态：磁盘保留它上一次的有效版本，不连累其它提供商', (
      WidgetTester tester,
    ) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
        _config(id: 'p2', name: 'Beta', baseUrl: 'https://api.deepseek.com/v1'),
      ]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments().withAssignment(
          AiFeature.galgameTextProcess,
          'p1',
        ),
      );
      await pumpSection(tester);
      await openEditor(tester, 'p1');

      // `htt` 不是合法地址：这条草稿本轮无效（它仍留在界面上，不报错也不弹窗——
      // 用户只是还没打完）。回归点（S1）：此前无效草稿直接被跳过、整份覆盖落盘，
      // 于是 p1 从磁盘消失、指向它的功能映射悬空，此刻离开页面就永久丢了这家。
      await enter(tester, 'ai-provider-0-base-url', 'htt');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(prefs.aiProviders.map((AiProviderConfig c) => c.id), <String>[
        'p1',
        'p2',
      ], reason: '一条草稿编辑到一半不是删除');
      expect(
        prefs.aiProviders.first.baseUrl.toString(),
        'https://api.openai.com/v1',
        reason: '磁盘上是这家上一次的有效版本',
      );
      expect(
        prefs.aiProviders.first.enabled,
        isFalse,
        reason: '保留的旧版本停用落盘：正在改的配置不在后台继续被调用',
      );
      expect(
        prefs.aiFeatureAssignments.providerIdFor(AiFeature.galgameTextProcess),
        'p1',
        reason: '映射不悬空',
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
      expect(
        prefs.aiFeatureAssignments
            .resolve(AiFeature.galgameTextProcess, prefs.aiProviders)
            ?.id,
        'p1',
        reason: '草稿重新有效即按草稿自己的启用状态写回，指派照常生效',
      );
    });

    testWidgets('页面开着时别处（fushi_cli）改了清单：没改过的草稿跟着刷新，保存只写本页改过的那家', (
      WidgetTester tester,
    ) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
        _config(id: 'p2', name: 'Beta', baseUrl: 'https://api.deepseek.com/v1'),
      ]);
      await pumpSection(tester);

      // 别处：改 p2 的模型、新增 p3、指派默认。
      await prefs.setAiProviders(<AiProviderConfig>[
        prefs.aiProviders.first,
        _config(
          id: 'p2',
          name: 'Beta',
          baseUrl: 'https://api.deepseek.com/v1',
          model: 'deepseek-chat',
        ),
        _config(id: 'p3', name: 'Gamma', model: 'gpt-5'),
      ]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments().withDefault('p3'),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('ai-provider-p3')),
        findsOneWidget,
      );

      // 本页：只改 p1 的模型。
      await openEditor(tester, 'p1');
      await enter(tester, 'ai-provider-0-model', 'gpt-4.1');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      final Map<String, AiProviderConfig> saved = <String, AiProviderConfig>{
        for (final AiProviderConfig c in prefs.aiProviders) c.id: c,
      };
      expect(saved.keys, <String>['p1', 'p2', 'p3']);
      expect(saved['p1']!.model, 'gpt-4.1');
      expect(saved['p2']!.model, 'deepseek-chat', reason: '陈旧草稿不能覆盖别处的改动');
      expect(saved['p3']!.model, 'gpt-5', reason: '别处新增的保留');
      expect(prefs.storedAiFeatureAssignments.defaultProviderId, 'p3');
    });

    testWidgets('外层只放总配置：功能指派默认折叠，摘要报单独指定了几项', (WidgetTester tester) async {
      debugSettingsForceExpandAllSections = false;
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
      ]);
      await pumpSection(tester);

      final Finder providerList = find.byKey(
        const ValueKey<String>('ai-provider-list'),
      );
      expect(
        find.descendant(
          of: providerList,
          matching: find.byKey(const ValueKey<String>('ai-feature-default')),
        ),
        findsOneWidget,
        reason: '默认提供商属于总配置，跟提供商清单一起常显',
      );
      final Finder featureRow = find.byKey(
        ValueKey<String>(
          'ai-feature-${AiFeature.galgameTextProcess.storageKey}',
        ),
      );
      expect(featureRow, findsNothing, reason: '各功能的单独指派默认收起');
      expect(find.text(t.ai_feature_overrides_none), findsOneWidget);

      await tester.tap(find.text(t.ai_features_section));
      await tester.pumpAndSettle();
      expect(featureRow, findsOneWidget, reason: '点分组头展开后功能行出现');
    });

    testWidgets('手机宽度：功能行的说明不被下拉按钮挤成一字一行，按钮落到说明下一行', (
      WidgetTester tester,
    ) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'LM Studio (local, long provider name)'),
      ]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments(defaultProviderId: 'p1'),
      );
      // 测试字体（Ahem）的字形远宽于真字体：缩到 0.5 倍让折叠头等无关部件不溢出，
      // 本测试只量设置行的堆叠判据。
      await pumpSection(tester, width: 360, textScale: 0.5);

      final Finder summary = find.text(
        t.ai_feature_galgame_text_process_summary,
      );
      final Finder button = find.byKey(
        ValueKey<String>(
          'ai-feature-${AiFeature.galgameTextProcess.storageKey}-provider',
        ),
      );
      await tester.ensureVisible(summary);
      await tester.pumpAndSettle();

      // 堆叠前标题 / 说明只剩十几 dp（BUG-2550 同款挤压）；堆叠后拿到整行宽。
      expect(tester.getSize(summary).width, greaterThan(200));
      expect(
        tester.getTopLeft(button).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(summary).dy),
        reason: '窄行里下拉按钮应在说明下面，而不是挤在它右边',
      );
    });

    for (final bool apple in <bool>[false, true]) {
      testWidgets(
        '[${apple ? 'Apple' : 'MD3'}] 功能行声明的 trailingWidth 就是下拉按钮的真实最大宽',
        (WidgetTester tester) async {
          // 名字远超当前值文字上限：按钮顶到最大宽。
          await prefs.setAiProviders(<AiProviderConfig>[
            _config(
              id: 'p1',
              name: 'An extremely long provider name that never fits the cap',
            ),
          ]);
          await prefs.setAiFeatureAssignments(
            const AiFeatureAssignments(defaultProviderId: 'p1'),
          );
          await pumpSection(tester, width: 900, apple: apple);

          final Finder button = find.byKey(
            ValueKey<String>(
              'ai-feature-${AiFeature.galgameTextProcess.storageKey}-provider',
            ),
          );
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          final AdaptiveSettingsRow row = tester.widget<AdaptiveSettingsRow>(
            find.ancestor(
              of: button,
              matching: find.byType(AdaptiveSettingsRow),
            ),
          );
          final double declared = row.trailingWidth!;
          // 堆叠判据按 declared 算：它与按钮实宽对不上，窄屏就会误判行内 / 堆叠。
          expect(tester.getSize(button).width, closeTo(declared, 0.5));
        },
      );
    }

    testWidgets('[Apple] 手机宽度：功能行的下拉按钮落到说明下一行', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'LM Studio (local, long provider name)'),
      ]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments(defaultProviderId: 'p1'),
      );
      await pumpSection(tester, width: 360, textScale: 0.5, apple: true);

      final Finder summary = find.text(
        t.ai_feature_galgame_text_process_summary,
      );
      final Finder button = find.byKey(
        ValueKey<String>(
          'ai-feature-${AiFeature.galgameTextProcess.storageKey}-provider',
        ),
      );
      await tester.ensureVisible(summary);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(button).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(summary).dy),
        reason: '窄行里下拉按钮应在说明下面，而不是挤在它右边',
      );
    });

    testWidgets('折叠头摘要：单独指定（含「不使用 AI」）几项就报几项', (WidgetTester tester) async {
      debugSettingsForceExpandAllSections = false;
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
      ]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments(defaultProviderId: 'p1')
            .withAssignment(AiFeature.galgameTextProcess, 'p1')
            .withAssignment(AiFeature.dictStyle, kAiFeatureDisabled),
      );
      await pumpSection(tester);
      expect(find.text(t.ai_feature_overrides_count(n: 2)), findsOneWidget);
    });

    testWidgets('单独指定过的功能行带「改过默认值」标记，恢复默认即跟随默认', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
      ]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments(
          defaultProviderId: 'p1',
        ).withAssignment(AiFeature.galgameTextProcess, kAiFeatureDisabled),
      );
      await pumpSection(tester);

      SettingsModifiedRow marker(AiFeature feature) =>
          tester.widget<SettingsModifiedRow>(
            find.byKey(
              ValueKey<String>('ai-feature-${feature.storageKey}-modified'),
            ),
          );
      expect(marker(AiFeature.galgameTextProcess).modified, isTrue);
      expect(marker(AiFeature.dictStyle).modified, isFalse);

      final Finder reset = find.descendant(
        of: find.byKey(
          ValueKey<String>(
            'ai-feature-${AiFeature.galgameTextProcess.storageKey}-modified',
          ),
        ),
        matching: find.byKey(const ValueKey<String>('settings-reset-default')),
      );
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();

      expect(
        prefs.aiFeatureAssignments.providerIdFor(AiFeature.galgameTextProcess),
        isNull,
      );
      expect(marker(AiFeature.galgameTextProcess).modified, isFalse);
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

    testWidgets('默认提供商选一次 → 所有没单独指定的功能都用它', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
      ]);
      await pumpSection(tester);

      await tapKey(tester, 'ai-feature-default-provider');
      await tester.tap(find.text('Alpha').last);
      await tester.pumpAndSettle();

      final AiFeatureAssignments saved = prefs.aiFeatureAssignments;
      expect(saved.defaultProviderId, 'p1');
      for (final AiFeature feature in AiFeature.values) {
        // 云端语音转录上传音频、按量计费：只认显式指派，不跟随默认。
        expect(
          saved.resolve(feature, prefs.aiProviders)?.id,
          feature.followsDefaultProvider ? 'p1' : isNull,
          reason: feature.name,
        );
      }
      // 功能行把「跟随默认」连同那家的名字一起显示出来，而不是「未指定」。
      expect(find.textContaining('Alpha'), findsWidgets);
    });

    testWidgets('显式指派的那家没配全：显示「不可用」而不是「跟随默认」', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
        _config(id: 'p2', name: 'Beta', apiKey: ''),
      ]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments(
          defaultProviderId: 'p1',
        ).withAssignment(AiFeature.galgameTextProcess, 'p2'),
      );
      await pumpSection(tester);

      final Finder row = find.byKey(
        ValueKey<String>(
          'ai-feature-${AiFeature.galgameTextProcess.storageKey}',
        ),
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(t.ai_feature_assigned_unavailable),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(t.ai_feature_follow_default(name: 'Alpha')),
        ),
        findsNothing,
      );
      // 与运行时一致：显式那家失效不回退默认。
      expect(
        prefs.aiFeatureAssignments.resolve(
          AiFeature.galgameTextProcess,
          prefs.aiProviders,
        ),
        isNull,
      );
    });

    testWidgets('功能行选「不使用 AI」压过默认', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
      ]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments(defaultProviderId: 'p1'),
      );
      await pumpSection(tester);

      await tapKey(
        tester,
        'ai-feature-${AiFeature.galgameTextProcess.storageKey}-provider',
      );
      await tester.tap(find.text(t.ai_feature_disabled).last);
      await tester.pumpAndSettle();

      final AiFeatureAssignments saved = prefs.aiFeatureAssignments;
      expect(
        saved.resolve(AiFeature.galgameTextProcess, prefs.aiProviders),
        isNull,
      );
      expect(saved.resolve(AiFeature.dictStyle, prefs.aiProviders)?.id, 'p1');
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
      await openEditor(tester, 'p1');

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

    testWidgets('关掉明文 HTTP 放行使校验失败：这家不从磁盘消失，指派不悬空', (
      WidgetTester tester,
    ) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(
          id: 'p1',
          name: 'LAN',
          baseUrl: 'http://192.168.1.20:8000/v1',
          allowInsecureHttp: true,
        ),
      ]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments(defaultProviderId: 'p1'),
      );
      await pumpSection(tester);
      await openEditor(tester, 'p1');

      await tapKey(tester, 'ai-provider-0-allow-http');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(prefs.aiProviders, hasLength(1), reason: '只有显式删除能移除一家');
      expect(prefs.aiFeatureAssignments.defaultProviderId, 'p1');
      // 用户撤回了明文 HTTP 放行：旧版本（仍放行明文）不能照原样留着继续被调用。
      expect(prefs.aiProviders.single.enabled, isFalse);
      expect(
        prefs.aiFeatureAssignments.resolve(
          AiFeature.galgameTextProcess,
          prefs.aiProviders,
        ),
        isNull,
        reason: '撤回放行后不再经明文 HTTP 发任何 AI 请求',
      );
    });

    testWidgets('从没有效过的新草稿不落盘，删除照样移除持久化的那家', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[_config(id: 'p1')]);
      await pumpSection(tester);

      await tapKey(tester, 'ai-provider-add');
      await tapKey(tester, 'ai-provider-preset-$kAiCustomPresetId');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      // 「自定义」预设没有地址：草稿无效，磁盘上本来就没有它，不能凭空写一条。
      expect(prefs.aiProviders.map((AiProviderConfig c) => c.id), <String>[
        'p1',
      ]);

      // 上一次有效版本的回落只覆盖「还在草稿列表里」的 id：删掉就是删掉。
      // （新增后自动进了新草稿的编辑页：退回列表再进 p1。）
      await closeEditor(tester);
      await openEditor(tester, 'p1');
      await enter(tester, 'ai-provider-0-base-url', 'htt');
      await tapKey(tester, 'ai-provider-0-delete');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(prefs.aiProviders, isEmpty);
    });

    testWidgets('显式指派指向清单里不存在的 id：显示「不可用」，与运行时 resolve 同口径', (
      WidgetTester tester,
    ) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', name: 'Alpha'),
      ]);
      // 备份恢复 / 旧版本写入 / 条目解码失败都会留下这种映射（删除时已清的除外）。
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments(
          defaultProviderId: 'p1',
        ).withAssignment(AiFeature.galgameTextProcess, 'gone'),
      );
      await pumpSection(tester);

      final Finder row = find.byKey(
        ValueKey<String>(
          'ai-feature-${AiFeature.galgameTextProcess.storageKey}',
        ),
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(t.ai_feature_assigned_unavailable),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(t.ai_feature_follow_default(name: 'Alpha')),
        ),
        findsNothing,
        reason: '运行时显式指派找不到时不回退默认，界面不能说「跟随默认」',
      );
      expect(
        prefs.aiFeatureAssignments.resolve(
          AiFeature.galgameTextProcess,
          prefs.aiProviders,
        ),
        isNull,
      );
    });

    Future<void> pumpWithClient(
      WidgetTester tester,
      Future<http.Response> Function(http.Request request) handler,
    ) async {
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
                    clientFactory: () =>
                        AiChatClient(client: MockClient(handler)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    http.Response jsonResponse(Object? body, {int status = 200}) =>
        http.Response(
          jsonEncode(body),
          status,
          headers: <String, String>{'content-type': 'application/json'},
        );

    testWidgets('测试连接对所配模型发 chat：模型列表能拉但 chat 404 → 判失败', (
      WidgetTester tester,
    ) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', model: 'gpt-typo'),
      ]);
      final List<http.Request> seen = <http.Request>[];
      await pumpWithClient(tester, (http.Request request) async {
        seen.add(request);
        if (request.url.path.endsWith('/models')) {
          return jsonResponse(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{'id': 'gpt-4o-mini'},
            ],
          });
        }
        return jsonResponse(<String, Object?>{
          'error': 'model not found',
        }, status: 404);
      });

      await openEditor(tester, 'p1');
      await tapKey(tester, 'ai-provider-0-test');

      // 回归点（S4）：此前只跑 listModels，模型名拼错照样「连接正常」。
      expect(seen, hasLength(1));
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/v1/chat/completions');
      final Map<String, Object?> payload =
          jsonDecode(seen.single.body) as Map<String, Object?>;
      expect(payload['model'], 'gpt-typo');
      expect(
        find.text(t.ai_provider_test_failed(reason: aiFailureText('http_404'))),
        findsOneWidget,
      );
      expect(find.text(t.ai_provider_test_ok), findsNothing);
    });

    testWidgets('测试连接：chat 应答形状正确即通过（推理模型正文为空也算通）', (
      WidgetTester tester,
    ) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', model: 'o4-mini'),
      ]);
      await pumpWithClient(
        tester,
        (http.Request request) async => jsonResponse(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{'content': ''},
              'finish_reason': 'length',
            },
          ],
        }),
      );

      await openEditor(tester, 'p1');
      await tapKey(tester, 'ai-provider-0-test');
      expect(find.text(t.ai_provider_test_ok), findsOneWidget);
    });

    testWidgets('测试连接：还没填模型时退回列模型（验地址与鉴权）', (WidgetTester tester) async {
      await prefs.setAiProviders(<AiProviderConfig>[
        _config(id: 'p1', model: ''),
      ]);
      final List<http.Request> seen = <http.Request>[];
      await pumpWithClient(tester, (http.Request request) async {
        seen.add(request);
        return jsonResponse(<String, Object?>{'data': <Object?>[]});
      });

      await openEditor(tester, 'p1');
      await tapKey(tester, 'ai-provider-0-test');
      expect(seen.single.method, 'GET');
      expect(seen.single.url.path, '/v1/models');
      expect(find.text(t.ai_provider_test_ok), findsOneWidget);
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
      await openEditor(tester, 'p1');

      // 迁移面：老用户落盘的模型名必须原样回显在字段里（字段仍是自由文本，
      // 候选只是辅助输入；写不进去就等于升级后把人家的自定义模型名吞了）。
      expect(
        tester
            .widget<TextField>(
              glassUnwrap<TextField>(
                find.descendant(
                  of: find.byKey(const ValueKey<String>('ai-provider-0-model')),
                  matching: find.byType(TextField),
                ),
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
              glassUnwrap<TextField>(
                find.descendant(
                  of: find.byKey(const ValueKey<String>('ai-provider-0-model')),
                  matching: find.byType(TextField),
                ),
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

    Matcher failsWith(String code) => throwsA(
      isA<AiChatFailure>().having(
        (AiChatFailure f) => f.message,
        'message',
        code,
      ),
    );

    test('三种协议同口径：正文为空 / 只有空白 → empty_response', () async {
      final List<(AiProviderConfig, Object?)> cases =
          <(AiProviderConfig, Object?)>[
            for (final String blank in <String>['', '  \n '])
              (
                _config(),
                <String, Object?>{
                  'choices': <Object?>[
                    <String, Object?>{
                      'message': <String, Object?>{'content': blank},
                    },
                  ],
                },
              ),
            (
              _config(
                presetId: 'anthropic',
                baseUrl: 'https://api.anthropic.com',
                model: 'claude-sonnet-5',
                protocol: AiWireProtocol.anthropicMessages,
              ),
              <String, Object?>{
                'content': <Object?>[
                  <String, Object?>{'type': 'text', 'text': ' \n'},
                ],
              },
            ),
            (
              _config(
                presetId: 'gemini',
                baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
                model: 'gemini-2.5-flash',
                protocol: AiWireProtocol.geminiGenerateContent,
              ),
              <String, Object?>{
                'candidates': <Object?>[
                  <String, Object?>{
                    'content': <String, Object?>{
                      'parts': <Object?>[
                        <String, Object?>{'text': '   '},
                      ],
                    },
                  },
                ],
              },
            ),
          ];
      for (final (AiProviderConfig provider, Object? body) in cases) {
        final AiChatClient client = clientReturning(body);
        addTearDown(client.close);
        // 回归点（S3）：OpenAI 兼容协议此前把空 content 当成功原样返回。
        await expectLater(
          client.complete(
            provider: provider,
            messages: <AiChatMessage>[const AiChatMessage.user('hi')],
          ),
          failsWith('empty_response'),
          reason: provider.protocol.name,
        );
      }
    });

    test('OpenAI 官方端点发 max_completion_tokens，其余兼容端点仍发 max_tokens', () async {
      Future<Map<String, Object?>> payloadFor(String baseUrl) async {
        final AiChatClient client = clientReturning(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{'content': 'ok'},
            },
          ],
        });
        addTearDown(client.close);
        await client.complete(
          provider: _config(baseUrl: baseUrl, model: 'o4-mini'),
          messages: <AiChatMessage>[const AiChatMessage.user('hi')],
          maxTokens: 300,
        );
        return jsonDecode(capturedBody) as Map<String, Object?>;
      }

      // 回归点（S5）：官方推理模型（o 系列 / gpt-5）拒收 max_tokens。
      final Map<String, Object?> official = await payloadFor(
        'https://api.openai.com/v1',
      );
      expect(official['max_completion_tokens'], 300);
      expect(official.containsKey('max_tokens'), isFalse);

      final Map<String, Object?> compatible = await payloadFor(
        'https://api.deepseek.com/v1',
      );
      expect(compatible['max_tokens'], 300);
      expect(compatible.containsKey('max_completion_tokens'), isFalse);
    });

    test('ping：对所配模型发最小 chat，形状正确即通过、不要求正文', () async {
      final AiChatClient client = clientReturning(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': ''},
            'finish_reason': 'length',
          },
        ],
      });
      addTearDown(client.close);
      await client.ping(_config(baseUrl: 'https://api.deepseek.com/v1'));
      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/chat/completions');
      final Map<String, Object?> payload =
          jsonDecode(capturedBody) as Map<String, Object?>;
      expect(payload['model'], 'gpt-4o-mini');
      final int cap = payload['max_tokens']! as int;
      expect(cap, inInclusiveRange(16, 64), reason: '小但给推理模型留余量');
    });

    test('ping：应答不是该协议的形状 → bad_response；HTTP 错误照常映射', () async {
      final AiChatClient wrongShape = clientReturning(<String, Object?>{
        'error': 'gateway says hi',
      });
      addTearDown(wrongShape.close);
      await expectLater(wrongShape.ping(_config()), failsWith('bad_response'));

      final AiChatClient notFound = clientReturning(<String, Object?>{
        'error': 'no such model',
      }, status: 404);
      addTearDown(notFound.close);
      await expectLater(notFound.ping(_config()), failsWith('http_404'));

      final AiChatClient unused = clientReturning(<String, Object?>{});
      addTearDown(unused.close);
      await expectLater(
        unused.ping(_config(model: ' ')),
        failsWith('provider_not_configured'),
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
