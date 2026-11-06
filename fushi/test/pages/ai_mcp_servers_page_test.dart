// 「设置 › AI › AI 助手 › MCP 服务器」页（spec docs/specs/2026-11-05-ai-mcp-client-design.md §3），
// MD3 与 Apple 两套设计系统：
// - 空清单 → 一键添加 MangaBaka 预设（默认开着），预设加过后不再出现在添加菜单里；
// - 行内开关写回偏好；状态行按对话里的连接状态显示；
// - 编辑页：测试连接列出工具，关掉一个工具、开「每次都问」，保存后写回；删除。
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/mcp_client/ai_mcp_client_presets.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/ai_mcp_servers_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_config.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_session.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_toolbox.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  required bool apple,
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: home,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const List<McpRemoteTool> _tools = <McpRemoteTool>[
  McpRemoteTool(
    name: 'series_search',
    title: 'Search MangaBaka series',
    description: 'Search.',
    inputSchema: <String, Object?>{'type': 'object'},
    readOnly: true,
  ),
  McpRemoteTool(
    name: 'tags_find',
    title: 'Find tags',
    description: 'Tags.',
    inputSchema: <String, Object?>{'type': 'object'},
    readOnly: true,
  ),
];

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() => db.close());

  for (final bool apple in <bool>[false, true]) {
    final String system = apple ? 'Apple' : 'MD3';

    testWidgets(
      '$system: empty list → add MangaBaka preset; switch writes back',
      (WidgetTester tester) async {
        final List<String> opened = <String>[];
        await _pump(
          tester,
          AiMcpServersPage(
            prefs: prefs,
            liveStatuses: () => const <String, McpServerStatus>{
              'mangabaka': McpServerStatus(
                McpServerState.connected,
                toolCount: 18,
              ),
            },
            openEditor: (BuildContext context, String id) async =>
                opened.add(id),
          ),
          apple: apple,
        );
        expect(
          find.byKey(const ValueKey<String>('ai_mcp_servers_empty')),
          findsOneWidget,
        );
        // 新页面带错峰入场动效（UI 硬规则）。
        expect(find.byType(FushiEntranceScope), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey<String>('ai_mcp_servers_add')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(t.ai_mcp_client_add_preset(name: 'MangaBaka')),
        );
        await tester.pumpAndSettle();

        final McpServerConfig added = prefs.aiMcpClientServers.single;
        expect(added.presetId, kMangaBakaMcpPreset.id);
        expect(added.enabled, isTrue);
        expect(
          find.byKey(const ValueKey<String>('ai_mcp_server_mangabaka')),
          findsOneWidget,
        );
        expect(
          find.textContaining(t.ai_mcp_client_status_connected(n: 18)),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey<String>('ai_mcp_server_switch_mangabaka')),
        );
        await tester.pumpAndSettle();
        expect(prefs.aiMcpClientServers.single.enabled, isFalse);
        expect(find.textContaining(t.ai_mcp_client_status_off), findsOneWidget);

        // 预设只能加一次。
        await tester.tap(
          find.byKey(const ValueKey<String>('ai_mcp_servers_add')),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(t.ai_mcp_client_add_preset(name: 'MangaBaka')),
          findsNothing,
        );
        await tester.tap(find.text(t.ai_mcp_client_add_http));
        await tester.pumpAndSettle();
        expect(prefs.aiMcpClientServers, hasLength(2));
        expect(prefs.aiMcpClientServers.last.transport, McpTransportKind.http);
        // 新建的自定义 server 直接进编辑页。
        expect(opened, <String>[prefs.aiMcpClientServers.last.id]);

        await tester.tap(
          find.byKey(
            ValueKey<String>(
              'ai_mcp_server_${prefs.aiMcpClientServers.first.id}',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(opened.last, 'mangabaka');
      },
    );

    testWidgets('$system: edit page tests, toggles a tool, saves, deletes', (
      WidgetTester tester,
    ) async {
      await prefs.setAiMcpClientServers(<McpServerConfig>[
        kMangaBakaMcpPreset.toConfig(const <String>[]),
      ]);
      final List<McpServerConfig> probed = <McpServerConfig>[];
      await _pump(
        tester,
        AiMcpServerEditPage(
          prefs: prefs,
          serverId: 'mangabaka',
          probe: (McpServerConfig config) async {
            probed.add(config);
            return const McpProbeResult(
              status: McpServerStatus(McpServerState.connected, toolCount: 2),
              tools: _tools,
            );
          },
        ),
        apple: apple,
      );
      expect(find.byType(FushiEntranceScope), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('ai_mcp_edit_headers')),
        'X-Test: 1',
      );
      await tester.tap(find.byKey(const ValueKey<String>('ai_mcp_edit_test')));
      await tester.pumpAndSettle();
      expect(probed.single.headers, <String, String>{'X-Test': '1'});
      expect(
        find.byKey(const ValueKey<String>('ai_mcp_edit_tool_series_search')),
        findsOneWidget,
      );
      expect(find.text(t.ai_mcp_client_status_connected(n: 2)), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('ai_mcp_edit_tool_switch_tags_find')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('ai_mcp_edit_confirm_every_call')),
      );
      await tester.pumpAndSettle();
      // 保存之前不写盘。
      expect(prefs.aiMcpClientServers.single.disabledTools, isEmpty);

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('ai_mcp_edit_save')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('ai_mcp_edit_save')));
      await tester.pumpAndSettle();
      final McpServerConfig saved = prefs.aiMcpClientServers.single;
      expect(saved.disabledTools, <String>{'tags_find'});
      expect(saved.confirmEveryCall, isTrue);
      expect(saved.headers, <String, String>{'X-Test': '1'});
      expect(saved.url, 'https://api.mangabaka.org/mcp');
    });

    testWidgets('$system: invalid address disables Test; delete asks first', (
      WidgetTester tester,
    ) async {
      await prefs.setAiMcpClientServers(const <McpServerConfig>[
        McpServerConfig(id: 'custom', name: 'Custom'),
      ]);
      await _pump(
        tester,
        AiMcpServerEditPage(
          prefs: prefs,
          serverId: 'custom',
          probe: (_) async => fail('should not probe an incomplete server'),
        ),
        apple: apple,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('ai_mcp_edit_url')),
        'example.com',
      );
      await tester.pumpAndSettle();
      expect(find.text(t.ai_mcp_client_invalid_url), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('ai_mcp_edit_test')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('ai_mcp_edit_delete')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('ai_mcp_edit_delete')),
      );
      await tester.pumpAndSettle();
      expect(prefs.aiMcpClientServers, hasLength(1));
      await tester.tap(find.text(t.ai_mcp_client_delete).last);
      await tester.pumpAndSettle();
      expect(prefs.aiMcpClientServers, isEmpty);
    });
  }
}
