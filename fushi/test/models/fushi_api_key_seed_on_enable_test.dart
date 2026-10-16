// 用户在设置里**开启** Fushi API 服务器那一刻，空 key 自动播种一枚。
//
// 动机：复习模块开着时，Fushi API 根路径同时是 AnkiConnect v6 兼容端点，它在 key 为空时
// 只收回环请求（非本机 403），别的设备（手机上的 Fushi、局域网 Yomitan）连它必须带 key。
// 契约：
//  1. 关 → 开 且 key 为空：播种非空 key。
//  2. 关 → 开 但 key 非空：原样保留（覆盖会让已配好的客户端 401）。
//  3. 已开着（存量用户）+ 空 key：再置 true 不播种——主 Fushi API 一旦有 key，本机回环
//     请求也要带 key，静默生成会让不带 key 的本机客户端突然 401。
//  4. 关闭不播种。
//  5. 生产接线：设置开关走 setFushiApiServerEnabledByUser，状态行「生成密钥」只在空 key 时出现。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}

Future<AppModel> _prefsBackedAppModel() async {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'fushi_api_key_seed_',
  );
  addTearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  final AppModel appModel = _TestAppModel();
  return appModel
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

void main() {
  test('关 → 开且 key 为空：播种一枚非空 key', () async {
    final AppModel appModel = await _prefsBackedAppModel();
    expect(appModel.fushiApiServerEnabled, isFalse);
    expect(appModel.fushiApiKey, isEmpty);

    await appModel.setFushiApiServerEnabledByUser(true);

    expect(appModel.fushiApiServerEnabled, isTrue);
    expect(appModel.fushiApiKey, isNotEmpty);
  });

  test('关 → 开但 key 非空：原样保留，绝不覆盖', () async {
    final AppModel appModel = await _prefsBackedAppModel();
    await appModel.setFushiApiKey('user-existing-key');

    await appModel.setFushiApiServerEnabledByUser(true);

    expect(appModel.fushiApiServerEnabled, isTrue);
    expect(appModel.fushiApiKey, 'user-existing-key');
  });

  test('已开着 + 空 key 的存量用户：不播种', () async {
    final AppModel appModel = await _prefsBackedAppModel();
    await appModel.setFushiApiServerEnabled(true);

    await appModel.setFushiApiServerEnabledByUser(true);

    expect(appModel.fushiApiServerEnabled, isTrue);
    expect(
      appModel.fushiApiKey,
      isEmpty,
      reason: '已开着的空 key 用户不动，否则其不带 key 的本机客户端会突然 401',
    );
  });

  test('关闭不播种', () async {
    final AppModel appModel = await _prefsBackedAppModel();
    await appModel.setFushiApiServerEnabled(true);

    await appModel.setFushiApiServerEnabledByUser(false);

    expect(appModel.fushiApiServerEnabled, isFalse);
    expect(appModel.fushiApiKey, isEmpty);
  });

  test('seedFushiApiKeyIfEmpty：空才播种，非空返回 false 且不改', () async {
    final AppModel appModel = await _prefsBackedAppModel();

    expect(await appModel.seedFushiApiKeyIfEmpty(), isTrue);
    final String seeded = appModel.fushiApiKey;
    expect(seeded, isNotEmpty);

    expect(await appModel.seedFushiApiKeyIfEmpty(), isFalse);
    expect(appModel.fushiApiKey, seeded);
  });

  test('生产接线：设置开关走 ByUser 入口，生成密钥按钮只在空 key 时出现', () {
    final String src = File(
      'lib/src/settings/settings_schema_lookup.dart',
    ).readAsStringSync();
    final int switchIdx = src.indexOf("id: 'lookup.fushi_api_server',");
    final int keyIdx = src.indexOf("id: 'lookup.fushi_api_key',");
    expect(switchIdx, greaterThanOrEqualTo(0));
    expect(keyIdx, greaterThan(switchIdx));
    expect(
      src
          .substring(switchIdx, keyIdx)
          .contains('setFushiApiServerEnabledByUser('),
      isTrue,
      reason: '设置开关必须走「从关到开时空 key 播种」的入口',
    );

    final int statusIdx = src.indexOf("id: 'lookup.srs_ankiconnect',");
    expect(statusIdx, greaterThanOrEqualTo(0));
    final String statusTail = src.substring(statusIdx);
    final String statusItem = statusTail.substring(
      0,
      statusTail.indexOf("id: 'lookup.texthooker',"),
    );
    expect(statusItem.contains('seedFushiApiKeyIfEmpty()'), isTrue);
    expect(
      statusItem.contains('actionVisible: (SettingsContext c) =>'),
      isTrue,
      reason: '「生成密钥」只在空 key 时出现',
    );
  });
}
