import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2586：在线服务 → AniDB 行的状态曾按「用户名 / 密码 / 客户端名 / 客户端
/// 版本」四个偏好键各自判空。客户端名留空时真实登录路径走内置 `fushiplayer`
/// 身份，「测试登录」成功了，状态行却仍显示「未配置」。状态必须与登录 / 协调器
/// 共用同一份 [VideoSourceScrapeGlobalConfig] 快照。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'hibiki_anidb_status_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    appModel = _TestAppModel()
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
  });
  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  Future<SettingsContext> pumpContext(WidgetTester tester) async {
    late SettingsContext settingsContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
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
    return settingsContext;
  }

  SettingsNavigationItem aniDbRow() => buildServicesDestination()
      .sections
      .expand((SettingsSection s) => s.items)
      .firstWhere(
        (SettingsItem i) => i.id == 'services.metadata.configure',
      ) as SettingsNavigationItem;

  testWidgets('账号填齐、客户端留空走内置身份 → 状态「已配置」', (WidgetTester tester) async {
    final SettingsContext settingsContext = await pumpContext(tester);
    final SettingsNavigationItem row = aniDbRow();

    expect(row.resolveSubtitle(settingsContext), t.settings_service_disabled);

    await prefs.setPref(kVideoAniDbHashEnabledPref, true);
    expect(
      row.resolveSubtitle(settingsContext),
      t.settings_service_not_configured,
    );

    await prefs.setPref(kVideoAniDbUsernamePref, 'tester');
    await prefs.setPref(kVideoAniDbPasswordPref, 'password');
    expect(
      row.resolveSubtitle(settingsContext),
      t.settings_service_configured,
      reason: '这正是 testAniDbLogin 会登录成功的配置，状态不能再说「未配置」',
    );
  });

  testWidgets('自定义客户端只填名字不填版本 → 「未配置」；补上版本 → 「已配置」', (
    WidgetTester tester,
  ) async {
    final SettingsContext settingsContext = await pumpContext(tester);
    final SettingsNavigationItem row = aniDbRow();
    await prefs.setPref(kVideoAniDbHashEnabledPref, true);
    await prefs.setPref(kVideoAniDbUsernamePref, 'tester');
    await prefs.setPref(kVideoAniDbPasswordPref, 'password');
    await prefs.setPref(kVideoMetadataAniDbClientNamePref, 'customapp');

    expect(
      row.resolveSubtitle(settingsContext),
      t.settings_service_not_configured,
      reason: '自定义客户端替换整对身份，没版本时 UDP 配置不可用、登录发不出去',
    );

    await prefs.setPref(kVideoMetadataAniDbClientVersionPref, '2');
    expect(row.resolveSubtitle(settingsContext), t.settings_service_configured);
  });

  test('status row must not re-derive readiness from individual pref keys', () {
    final String source = File(
      'lib/src/settings/settings_schema_services.dart',
    ).readAsStringSync();
    final int start = source.indexOf("id: 'services.metadata.configure'");
    final int end = source.indexOf('child: () => SettingsDestination(', start);
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final String subtitleBuilder = source.substring(start, end);
    expect(subtitleBuilder, contains('anidbHashReady'));
    for (final String key in <String>[
      'kVideoAniDbUsernamePref',
      'kVideoAniDbPasswordPref',
      'kVideoMetadataAniDbClientNamePref',
      'kVideoMetadataAniDbClientVersionPref',
    ]) {
      expect(
        subtitleBuilder,
        isNot(contains(key)),
        reason: '$key：状态行别按单个偏好键判空，走 config.anidbHashReady',
      );
    }
  });
}

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}
