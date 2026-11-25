import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preference_keys.dart'
    show kKnownPreferenceKeys;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/settings_index.dart' show isModelWritableSetting;
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_action.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_kit.dart'
    show SettingsResetSpec, settingsResetSpecFor;
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/settings_sync.dart' show PortableSettingsPolicy;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 「设置 › AI › 卡片字段 AI」：输出语言 + 提示词行。折叠摘要数改动、单项恢复默认删覆盖、
/// 提示词行 userOnly（AI 助手写不进也恢复不了）、输出语言真写穿并决定交给 AI 的语言名。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;

  SettingsSection section() => buildAiDestination().sections.singleWhere(
    (SettingsSection candidate) => candidate.id == 'ai.field_actions',
  );

  SettingsItem item(String id) => section().items.singleWhere(
    (SettingsItem candidate) => candidate.id == id,
  );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_ai_field_actions_',
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

  testWidgets('折叠；摘要数改动（输出语言 + 改过的内置提示词）；单项恢复默认删覆盖', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    expect(section().presentation, SettingsSectionPresentation.collapsed);
    expect(section().summaryBuilder!(settingsContext), isNull);
    // 每个内置动作一行；没有全局「总体说明」行了（AI 说明按动作存）。
    for (final AiSrsFieldTemplate template in kAiSrsFieldTemplates) {
      expect(item('ai.field_prompt.${template.id}'), isA<SettingsCustomItem>());
    }
    expect(
      section().items.map((SettingsItem i) => i.id),
      isNot(contains('ai.field_prompt.system')),
    );
    expect(
      section().items.where(
        (SettingsItem i) => i.id.startsWith('ai.field_prompt.task.'),
      ),
      hasLength(4),
    );

    await prefs.setAiFieldActions(
      AiSrsFieldActions.empty.withTemplatePrompt(
        'task.define',
        aiSrsFieldTaskTemplate(
          AiSrsFieldTask.define,
        ).prompt.copyWith(template: 'Mine.'),
      ),
    );
    expect(
      section().summaryBuilder!(settingsContext),
      t.settings_section_modified_count(n: 1),
    );
    await prefs.setAiOutputLanguage('ja');
    expect(
      section().summaryBuilder!(settingsContext),
      t.settings_section_modified_count(n: 2),
    );
    // 变体不算「改了默认」。
    final (AiSrsFieldActions withVariant, _) = prefs.aiFieldActions.addVariant(
      task: AiSrsFieldTask.translate,
      name: 'Literal',
      prompt: aiSrsFieldTaskTemplate(
        AiSrsFieldTask.translate,
      ).prompt.copyWith(template: 'Translate literally: {{Sentence}}'),
    );
    await prefs.setAiFieldActions(withVariant);
    expect(
      section().summaryBuilder!(settingsContext),
      t.settings_section_modified_count(n: 2),
    );

    final SettingsResetSpec spec = settingsResetSpecFor(
      item('ai.field_prompt.task.define'),
      settingsContext,
    )!;
    expect(spec.modified, isTrue);
    await spec.reset();
    expect(prefs.aiFieldActions.isOverridden('task.define'), isFalse);
    expect(prefs.aiFieldActions.variants, hasLength(1), reason: '变体不受影响');
    expect(
      settingsResetSpecFor(
        item('ai.field_prompt.task.translate'),
        settingsContext,
      )!.modified,
      isFalse,
    );
  });

  testWidgets('提示词行 userOnly：AI 助手写不进；输出语言照常可写', (WidgetTester tester) async {
    await pumpContext(tester);
    for (final SettingsItem i in section().items) {
      if (i.id == 'ai.output_language') {
        expect(isModelWritableSetting(i.id, i), isTrue);
      } else {
        expect(isModelWritableSetting(i.id, i), isFalse, reason: i.id);
      }
    }
  });

  testWidgets('输出语言：写穿偏好；空 = 界面语言；交给 AI 的是语言名', (WidgetTester tester) async {
    await pumpContext(tester);
    final SettingsSegmentedItem<String> lang =
        item('ai.output_language') as SettingsSegmentedItem<String>;
    expect(lang.defaultValue, '');
    final List<String> values = <String>[
      for (final SettingsSegmentOption<String> o in lang.optionsFor(
        settingsContext,
      ))
        o.value,
    ];
    expect(values.first, '');
    expect(values, containsAll(<String>['en', 'ja', 'zh-Hans', 'zh-Hant']));

    await lang.onChanged(settingsContext, 'ja');
    expect(prefs.aiOutputLanguage, 'ja');
    expect(srsFieldAiOutputLanguage(appModel), '日本語');
    await lang.onChanged(settingsContext, '');
    expect(
      srsFieldAiOutputLanguage(appModel),
      srsFieldAiOutputLanguageName(
        srsFieldAiAppLanguageTag(LocaleSettings.currentLocale),
      ),
    );
    expect(srsFieldAiOutputLanguageName('en'), 'English');
    expect(srsFieldAiAppLanguageTag(AppLocale.zhCn), 'zh-Hans');
    expect(srsFieldAiOutputLanguageName('zh-Hant'), '繁體中文');
  });

  testWidgets('偏好里整串坏掉 = 当没有改动（用内置）', (WidgetTester tester) async {
    await prefs.setPref(kAiFieldActionsPrefKey, '[not an object]');
    expect(prefs.aiFieldActions, AiSrsFieldActions.empty);
    await prefs.setAiFieldActions(AiSrsFieldActions.empty);
    expect(prefs.getPref(kAiFieldActionsPrefKey, defaultValue: ''), '');
  });

  test('提示词改动与 AI 输出语言设备本地：不进设置同步、备份、Profile 快照 / 分享', () {
    // 与 ai_providers / ai_feature_providers 同一条判据（fushi/CLAUDE.md「AI 配置设备本地」）。
    for (final String key in <String>[
      kAiFieldActionsPrefKey,
      'ai_output_language',
    ]) {
      expect(SyncRepository.deviceLocalPrefKeys, contains(key));
      expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isTrue);
      expect(ProfileKeys.isExcludedPref(key), isTrue);
      expect(PortableSettingsPolicy.isPortable(key), isFalse);
      expect(kKnownPreferenceKeys, contains(key));
    }
    // 已保存的提示词不在这次改动里：照旧跨设备。
    expect(
      SyncRepository.deviceLocalPrefKeys,
      isNot(contains('ai_saved_prompts')),
    );
  });
}
