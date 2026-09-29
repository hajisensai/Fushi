import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/ai/web_knowledge.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/ai_web_knowledge_sites_section.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 「联网资料」段的窄测试：每个内置站一个开关、真写穿偏好仓库、排在「AI 下视频」
/// 之前且不受下载模块门控；自定义 MediaWiki 站点列表的添加 / 校验 / 开关 / 删除。coverage 大表（settings_schema_coverage_test）里这几行
/// 登记在 `kCoveredElsewhere` 指到这里——生效点是 AI 下视频 / 视频识别构造
/// `WebKnowledgeClient` 时读的来源集合，harness 里没有那条链路。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;

  List<SettingsSection> sections() => buildAiDestination().sections;

  SettingsSection section() => sections().singleWhere(
    (SettingsSection candidate) => candidate.id == 'ai.web_knowledge',
  );

  SettingsSwitchItem item(String siteId) =>
      section().items.singleWhere(
            (SettingsItem candidate) =>
                candidate.id == 'ai.web_knowledge.$siteId',
          )
          as SettingsSwitchItem;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_ai_web_knowledge_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
  });

  tearDown(() => db.close());

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              settingsContext = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  testWidgets(
    'one switch per builtin site + custom list, before AI video download',
    (WidgetTester tester) async {
      await pumpContext(tester);
      expect(section().items.map((SettingsItem i) => i.id), <String>[
        for (final WebKnowledgeSite s in kBuiltinWebKnowledgeSites)
          'ai.web_knowledge.${s.id}',
        'ai.web_knowledge.custom',
      ]);
      expect(
        section().items.whereType<SettingsSwitchItem>().map(
          (SettingsSwitchItem i) => i.title,
        ),
        <String>[
          for (final WebKnowledgeSite s in kBuiltinWebKnowledgeSites)
            webKnowledgeSiteDisplayLabel(s),
        ],
      );
      final List<String?> ids = sections()
          .map((SettingsSection s) => s.id)
          .toList();
      expect(
        ids.indexOf('ai.web_knowledge'),
        lessThan(ids.indexOf('ai.video_download')),
      );
      expect(section().footer, contains('MediaWiki'));
    },
  );

  testWidgets('builtin switches default on and write through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    for (final WebKnowledgeSite s in kBuiltinWebKnowledgeSites) {
      expect(item(s.id).value(settingsContext), isTrue, reason: '从未写过 = 全开');
    }

    await item('tvmaze').onChanged(settingsContext, false);
    expect(
      prefs.aiWebKnowledgeSites.map((WebKnowledgeSite s) => s.id),
      <String>[
        'wikipedia_zh',
        'wikipedia_ja',
        'wikipedia_en',
        'moegirl',
        'ann',
      ],
    );
    expect(item('tvmaze').value(settingsContext), isFalse);

    // 全关后重载仍是全关：空串不能被当成「没写过」回落到默认全开。
    for (final WebKnowledgeSite s in kBuiltinWebKnowledgeSites) {
      await item(s.id).onChanged(settingsContext, false);
    }
    PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.aiWebKnowledgeSites, isEmpty);

    await item('ann').onChanged(settingsContext, true);
    reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(
      reloaded.aiWebKnowledgeSites.map((WebKnowledgeSite s) => s.id),
      <String>['ann'],
    );
  });

  testWidgets('section is not gated by the downloads module', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    expect(section().isVisible(settingsContext), isTrue);
    await appModel.setModuleEnabled(ModuleId.browse, false);
    expect(section().isVisible(settingsContext), isTrue);
    await appModel.setModuleEnabled(ModuleId.browse, true);
  });

  group('custom MediaWiki sites', () {
    Future<void> pumpEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => appModel),
          ],
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: AiWebKnowledgeCustomSitesSection(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> addSite(
      WidgetTester tester, {
      required String name,
      required String endpoint,
    }) async {
      await tester.tap(
        find.byKey(const ValueKey<String>('ai-web-knowledge-custom-add')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('ai-web-knowledge-custom-name')),
        name,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('ai-web-knowledge-custom-endpoint')),
        endpoint,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('ai-web-knowledge-custom-confirm')),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('invalid endpoint keeps the dialog open with an error', (
      WidgetTester tester,
    ) async {
      await pumpEditor(tester);
      await addSite(
        tester,
        name: 'Bad',
        endpoint: 'http://onepiece.fandom.com/wiki/Main',
      );
      expect(
        find.byKey(const ValueKey<String>('ai-web-knowledge-custom-dialog')),
        findsOneWidget,
      );
      expect(
        find.text(t.ai_web_knowledge_custom_endpoint_invalid),
        findsOneWidget,
      );
      expect(prefs.aiWebKnowledgeCustomSites, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey<String>('ai-web-knowledge-custom-cancel')),
      );
      await tester.pumpAndSettle();
      expect(prefs.aiWebKnowledgeCustomSites, isEmpty);
    });

    testWidgets(
      'add → enabled even after the user touched switches; toggle; delete',
      (WidgetTester tester) async {
        // 用户先关过一个内置站：启用集已写过，新加的站必须被显式加进去。
        await setWebKnowledgeSiteEnabled(prefs, 'tvmaze', enabled: false);
        await pumpEditor(tester);

        await addSite(
          tester,
          name: 'One Piece Wiki',
          endpoint: 'https://onepiece.fandom.com/api.php',
        );
        final WebKnowledgeSite site = prefs.aiWebKnowledgeCustomSites.single;
        expect(site.id, startsWith(kWebKnowledgeCustomIdPrefix));
        expect(site.label, 'One Piece Wiki');
        expect(site.endpoint.toString(), 'https://onepiece.fandom.com/api.php');
        expect(prefs.aiWebKnowledgeSites.last, site);
        expect(find.text('One Piece Wiki'), findsOneWidget);

        // 整行点击 = 切换启用。
        await tester.tap(find.text('One Piece Wiki'));
        await tester.pumpAndSettle();
        expect(prefs.aiWebKnowledgeEnabledSiteIds, isNot(contains(site.id)));
        await tester.tap(
          find.byKey(
            ValueKey<String>('ai-web-knowledge-site-${site.id}-enabled'),
          ),
        );
        await tester.pumpAndSettle();
        expect(prefs.aiWebKnowledgeEnabledSiteIds, contains(site.id));

        await tester.tap(
          find.byKey(
            ValueKey<String>('ai-web-knowledge-site-${site.id}-remove'),
          ),
        );
        await tester.pumpAndSettle();
        expect(prefs.aiWebKnowledgeCustomSites, isEmpty);
        expect(prefs.aiWebKnowledgeEnabledSiteIds, isNot(contains(site.id)));
        expect(find.text('One Piece Wiki'), findsNothing);

        final PreferencesRepository reloaded = PreferencesRepository(db);
        await reloaded.loadFromDb();
        expect(reloaded.aiWebKnowledgeCustomSites, isEmpty);
        expect(
          reloaded.aiWebKnowledgeEnabledSiteIds,
          isNot(contains('tvmaze')),
          reason: '删自定义站不能顺手把内置站的选择冲掉',
        );
      },
    );
  });
}
