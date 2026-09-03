import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/discovery/sources/opds_discovery_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';

import '../../helpers/test_platform_services.dart';

/// 发现源注册表**不得**在偏好就绪前解引用 `prefsRepo`。
///
/// 为什么必须有这个文件：`mediaDiscoveryService` 这个 getter 原本一行 `prefsRepo`
/// 都不碰，OPDS 那一批把 `for (... in prefsRepo.discoveryOpdsServers)` 直接写进了
/// 源清单。而 `prefsRepo` 是 `_prefsRepo!`——`isPreferencesReady` 这个 getter 的
/// 存在本身就是「初始化早期 `_prefsRepo` 可以是 null」的证据。于是「偏好就绪前
/// 打开发现页 / 发现来源设置区」变成一条崩溃路径：
///
/// ```
/// #0  AppModel.prefsRepo                      app_model.dart
/// #1  AppModel.mediaDiscoveryService          app_model.dart
/// #2  _MediaDiscoveryPageState._buildControls media_discovery_page.dart
/// ```
///
/// 光加 `isPreferencesReady` 门还不够：注册表是懒建后常驻的**构造期快照**，
/// 偏好缺席时建出来的那份会把「用户配的服务器全都不见了」latch 到整个进程
/// 生命周期。所以第三条锁的是「偏好就绪后自动重建一次」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('偏好未就绪时取发现源注册表不抛，且不含任何 OPDS 源', () {
    final AppModel appModel = AppModel(testPlatformServices());
    expect(appModel.isPreferencesReady, isFalse,
        reason: '这条测试的前提就是偏好还没接上');

    late MediaDiscoveryService service;
    expect(() => service = appModel.mediaDiscoveryService, returnsNormally,
        reason: '偏好就绪前取注册表不得解引用 prefsRepo');

    expect(
      service.sources.whereType<OpdsDiscoverySource>(),
      isEmpty,
      reason: '偏好缺席时展不出用户自配的服务器，只能给一份内置源注册表',
    );
    // 内置源必须照常在场：门是「跳过 OPDS 展开」，不是「整个注册表塌成空」。
    expect(service.sources, isNotEmpty);
  });

  test('偏好就绪后第一次取用会重建注册表，用户自配的 OPDS 源随即在场', () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory dir =
        Directory.systemTemp.createTempSync('discovery_prefs_gate');
    final AppModel appModel = AppModel(testPlatformServices());

    // 偏好就绪前先取一次：这一步把「缺 OPDS 的注册表」种进缓存。
    final MediaDiscoveryService cold = appModel.mediaDiscoveryService;
    expect(cold.sources.whereType<OpdsDiscoverySource>(), isEmpty);

    await prefs.setDiscoveryOpdsServers(<OpdsServerConfig>[
      OpdsServerConfig(
        id: 'lib1',
        name: 'Library',
        catalogUrl: Uri.parse('https://books.example.com/api/v1/opds'),
      ),
    ]);
    appModel.wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    expect(appModel.isPreferencesReady, isTrue);

    final MediaDiscoveryService warm = appModel.mediaDiscoveryService;
    expect(
      warm.sources.whereType<OpdsDiscoverySource>().map(
            (MediaDiscoverySource s) => s.id,
          ),
      <String>[opdsSourceIdFor('lib1')],
      reason: '偏好缺席时建的那份快照必须被重建，否则用户配的服务器永远不出现',
    );
    // 再取一次必须命中缓存：重建只发生一次，不是每次取用都重建。
    expect(identical(appModel.mediaDiscoveryService, warm), isTrue);

    prefs.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });
}
