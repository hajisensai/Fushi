import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/ai/ai_video_acquisition_preferences.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart'
    show subtitleLanguageNativeName;

import '../helpers/test_platform_services.dart';

/// 「AI 下视频」两个默认值的窄测试：schema 项真写穿偏好仓库、选项集合由代码枚举
/// 生成、段落随下载模块门控。coverage 大表（settings_schema_coverage_test）里这两
/// 行登记在 `kCoveredElsewhere` 指到这里——生效点是对话流程的 reducer，harness
/// 里探不到。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;

  SettingsSection section() => buildAiDestination().sections.singleWhere(
    (SettingsSection candidate) => candidate.id == 'ai.video_download',
  );

  SettingsSegmentedItem<String> item(String id) =>
      section().items.singleWhere(
            (SettingsItem candidate) => candidate.id == id,
          )
          as SettingsSegmentedItem<String>;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_ai_video_download_',
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

  testWidgets('options are generated from the code enums', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsSegmentedItem<String> quality = item(
      'ai.video_download_quality',
    );
    expect(quality.dropdown, isTrue);
    expect(
      quality.options.map((SettingsSegmentOption<String> o) => o.value),
      <String>[
        '',
        kVideoAcquisitionPrefAsk,
        for (final VideoAcquisitionQuality q in VideoAcquisitionQuality.values)
          q.storageKey,
      ],
    );
    // 档位字面量不翻译；`any` 才有文案。
    expect(
      quality.options
          .firstWhere((SettingsSegmentOption<String> o) => o.value == '1080p')
          .label,
      '1080p',
    );

    final SettingsSegmentedItem<String> language = item(
      'ai.video_download_subtitle_language',
    );
    expect(language.dropdown, isTrue);
    expect(
      language.options.map((SettingsSegmentOption<String> o) => o.value),
      <String>[
        '',
        kVideoAcquisitionPrefAsk,
        kVideoAcquisitionSubtitleOriginal,
        ...kVideoAcquisitionSubtitleLanguageCodes,
        kVideoAcquisitionSubtitleNone,
      ],
    );
    for (final String code in kVideoAcquisitionSubtitleLanguageCodes) {
      expect(
        language.options
            .firstWhere((SettingsSegmentOption<String> o) => o.value == code)
            .label,
        subtitleLanguageNativeName(code),
        reason: '语言名用母语写法',
      );
    }
    // 每个选项都能被类型化封装认出来（设置页给得出的值，对话流程一定读得回）。
    for (final SettingsSegmentOption<String> o in quality.options) {
      expect(
        AiDownloadQualityPref.parse(o.value).encode(),
        o.value,
        reason: o.value,
      );
    }
    for (final SettingsSegmentOption<String> o in language.options) {
      expect(
        AiDownloadSubtitleLanguagePref.parse(o.value).encode(),
        o.value,
        reason: o.value,
      );
    }
  });

  testWidgets('both rows write through the preferences repository', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsSegmentedItem<String> quality = item(
      'ai.video_download_quality',
    );
    final SettingsSegmentedItem<String> language = item(
      'ai.video_download_subtitle_language',
    );
    expect(quality.selected(settingsContext), '', reason: '默认未设置');
    expect(language.selected(settingsContext), '', reason: '默认未设置');

    await quality.onChanged(settingsContext, '1080p');
    expect(prefs.aiVideoDownloadQuality, '1080p');
    expect(quality.selected(settingsContext), '1080p');
    expect(
      AiDownloadQualityPref.parse(prefs.aiVideoDownloadQuality),
      const AiDownloadQualityFixed(VideoAcquisitionQuality.p1080),
    );

    await quality.onChanged(settingsContext, kVideoAcquisitionPrefAsk);
    expect(
      AiDownloadQualityPref.parse(prefs.aiVideoDownloadQuality),
      AiDownloadQualityPref.ask,
    );

    await language.onChanged(settingsContext, 'ja');
    expect(prefs.aiVideoDownloadSubtitleLanguage, 'ja');
    expect(language.selected(settingsContext), 'ja');

    await language.onChanged(settingsContext, kVideoAcquisitionSubtitleNone);
    expect(
      AiDownloadSubtitleLanguagePref.parse(
        prefs.aiVideoDownloadSubtitleLanguage,
      ),
      AiDownloadSubtitleLanguagePref.none,
    );

    // 写穿的是 preferences 表，不是内存态：重新装载还在。
    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.aiVideoDownloadQuality, kVideoAcquisitionPrefAsk);
    expect(reloaded.aiVideoDownloadSubtitleLanguage, 'none');
  });

  testWidgets('source / bitrate rows: options from enums, write through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsSegmentedItem<VideoAcquisitionSourcePref> source =
        section().items.singleWhere(
              (SettingsItem candidate) =>
                  candidate.id == 'ai.video_download_source',
            )
            as SettingsSegmentedItem<VideoAcquisitionSourcePref>;
    final SettingsSegmentedItem<VideoAcquisitionBitratePref> bitrate =
        section().items.singleWhere(
              (SettingsItem candidate) =>
                  candidate.id == 'ai.video_download_bitrate',
            )
            as SettingsSegmentedItem<VideoAcquisitionBitratePref>;
    expect(
      source.options.map(
        (SettingsSegmentOption<VideoAcquisitionSourcePref> o) => o.value,
      ),
      VideoAcquisitionSourcePref.values,
    );
    expect(
      bitrate.options.map(
        (SettingsSegmentOption<VideoAcquisitionBitratePref> o) => o.value,
      ),
      VideoAcquisitionBitratePref.values,
    );
    expect(source.selected(settingsContext), VideoAcquisitionSourcePref.any);
    expect(bitrate.selected(settingsContext), VideoAcquisitionBitratePref.any);

    await source.onChanged(settingsContext, VideoAcquisitionSourcePref.bluray);
    await bitrate.onChanged(settingsContext, VideoAcquisitionBitratePref.high);
    expect(prefs.aiVideoDownloadSource, 'bluray');
    expect(prefs.aiVideoDownloadBitrate, 'high');

    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(
      VideoAcquisitionSourcePref.parse(reloaded.aiVideoDownloadSource),
      VideoAcquisitionSourcePref.bluray,
    );
    expect(
      VideoAcquisitionBitratePref.parse(reloaded.aiVideoDownloadBitrate),
      VideoAcquisitionBitratePref.high,
    );
    // 认不出的旧值 / 手改值等价于没设置。
    expect(
      VideoAcquisitionSourcePref.parse('dvd'),
      VideoAcquisitionSourcePref.any,
    );
  });

  testWidgets('skip extras switch writes the global download preference', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsSwitchItem item =
        section().items.singleWhere(
              (SettingsItem candidate) =>
                  candidate.id == 'ai.video_download_skip_extras',
            )
            as SettingsSwitchItem;
    expect(item.value(settingsContext), isFalse, reason: '默认整颗种子全下');
    await item.onChanged(settingsContext, true);
    expect(prefs.videoDownloadSkipExtras, isTrue);
    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.videoDownloadSkipExtras, isTrue);
  });

  testWidgets('section follows the downloads module gate', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    // 非 iOS 平台两条合规能力都在，只剩模块开关决定可见性。
    expect(StoreRestrictedCapability.downloads.isAvailable, isTrue);
    expect(StoreRestrictedCapability.externalDiscovery.isAvailable, isTrue);
    expect(section().isVisible(settingsContext), isTrue);

    await appModel.setModuleEnabled(ModuleId.browse, false);
    expect(section().isVisible(settingsContext), isFalse);

    await appModel.setModuleEnabled(ModuleId.browse, true);
    expect(section().isVisible(settingsContext), isTrue);
  });
}
