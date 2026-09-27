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
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 「联网资料」段的窄测试：每个来源一个开关、真写穿偏好仓库、排在「AI 下视频」
/// 之前且不受下载模块门控。coverage 大表（settings_schema_coverage_test）里这几行
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

  SettingsSwitchItem item(WebKnowledgeSource source) =>
      section().items.singleWhere(
            (SettingsItem candidate) =>
                candidate.id == 'ai.web_knowledge.${source.storageKey}',
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

  testWidgets('one switch per source, placed before AI video download', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    expect(section().items.map((SettingsItem i) => i.id), <String>[
      for (final WebKnowledgeSource s in WebKnowledgeSource.values)
        'ai.web_knowledge.${s.storageKey}',
    ]);
    final List<String?> ids = sections()
        .map((SettingsSection s) => s.id)
        .toList();
    expect(
      ids.indexOf('ai.web_knowledge'),
      lessThan(ids.indexOf('ai.video_download')),
    );
    expect(section().footer, isNotEmpty, reason: '要讲清楚 app 自己抓、AI 只能引用抓到的');
  });

  testWidgets('switches default on and write through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    for (final WebKnowledgeSource s in WebKnowledgeSource.values) {
      expect(item(s).value(settingsContext), isTrue, reason: '从未写过 = 全开');
    }

    await item(
      WebKnowledgeSource.wikipediaEn,
    ).onChanged(settingsContext, false);
    expect(prefs.aiWebKnowledgeSources, <WebKnowledgeSource>{
      WebKnowledgeSource.wikipediaZh,
      WebKnowledgeSource.wikipediaJa,
    });
    expect(
      item(WebKnowledgeSource.wikipediaEn).value(settingsContext),
      isFalse,
    );

    // 全关后重载仍是全关：空串不能被当成「没写过」回落到默认全开。
    await item(
      WebKnowledgeSource.wikipediaZh,
    ).onChanged(settingsContext, false);
    await item(
      WebKnowledgeSource.wikipediaJa,
    ).onChanged(settingsContext, false);
    PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.aiWebKnowledgeSources, isEmpty);

    await item(WebKnowledgeSource.wikipediaJa).onChanged(settingsContext, true);
    reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.aiWebKnowledgeSources, <WebKnowledgeSource>{
      WebKnowledgeSource.wikipediaJa,
    });
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
}
