import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/configured_subtitle_providers.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import '../../../helpers/test_platform_services.dart';

/// 「在线服务 → AJATT」开关的**生效**测试（settings_schema_coverage 的
/// kCoveredElsewhere 指到这里）。
///
/// 这个开关唯一的行为后果：在线字幕来源的唯一装配点
/// [createConfiguredVideoSubtitleProviders]（下载管线与浏览器扩展桥共用）装不装
/// [AjattVideoSubtitleProvider]。这里走设置页那一行真正的 onChanged 写偏好，再按
/// 生产装配函数取 provider 列表断言——不是只看偏好落盘。
void main() {
  late FushiDatabase db;
  late Directory tmp;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;
  int httpClientsCreated = 0;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('ajatt_setting_effect_');
    httpClientsCreated = 0;
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.runAsync(() async {
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);
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

  SettingsSwitchItem ajattRow() => buildServicesDestination().sections
      .expand((SettingsSection s) => s.items)
      .whereType<SettingsSwitchItem>()
      .singleWhere(
        (SettingsSwitchItem item) => item.id == 'services.subtitle_preferences',
      );

  Future<List<VideoSubtitleProvider>> configured(WidgetTester tester) async {
    late List<VideoSubtitleProvider> providers;
    await tester.runAsync(() async {
      providers = await createConfiguredVideoSubtitleProviders(
        prefs: prefs,
        httpClientFactory: () async {
          httpClientsCreated++;
          return MockClient(
            (http.Request request) async => http.Response('', 404),
          );
        },
        supportRootProvider: () async => tmp,
      );
    });
    return providers;
  }

  bool hasAjatt(List<VideoSubtitleProvider> providers) =>
      providers.whereType<AjattVideoSubtitleProvider>().isNotEmpty;

  testWidgets('AJATT row toggles whether the AJATT provider is assembled', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsSwitchItem row = ajattRow();
    expect(row.title, 'AJATT');

    // 默认开：零配置来源，开箱即用。
    expect(row.value(settingsContext), isTrue);
    expect(hasAjatt(await configured(tester)), isTrue);

    // 关掉：设置行写偏好 → 装配点不再装 AJATT，也不为它建 HTTP 客户端。
    await tester.runAsync(() async => row.onChanged(settingsContext, false));
    expect(row.value(settingsContext), isFalse);
    httpClientsCreated = 0;
    final List<VideoSubtitleProvider> off = await configured(tester);
    expect(hasAjatt(off), isFalse);
    expect(httpClientsCreated, off.length, reason: '关掉的来源不得再建网络客户端');

    // 打开：再装回来。
    await tester.runAsync(() async => row.onChanged(settingsContext, true));
    expect(row.value(settingsContext), isTrue);
    expect(hasAjatt(await configured(tester)), isTrue);
  });
}
