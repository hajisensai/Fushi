// TODO-1266：浏览器扩展「装完即用」守卫。
//
// 用户诉求：安装 Hibiki 浏览器扩展时，app 侧的 yomitan-api server 应默认开启，省得装完
// 连不上 401。实现落在 `AppModel.ensureYomitanApiServerForBrowserExtension()`，由设置页
// 「安装浏览器扩展」动作在解压/注入扩展前调用。本测试锁死其安全 + 幂等契约：
//  1. server 之前关闭 → 置位 enabled 并真启动 server（返回 true）。
//  2. token 为空 → 播种一枚非空 token（否则扩展虽连通但鉴权/展示不完整）。
//  3. **绝不覆盖**已有非空 token（覆盖会踢掉扩展已保存的 token → 401）。
//  4. server 已启用 → 跳过不重启（不打断在跑的连接）。
//  5. 生产接线守卫：设置页安装入口必须在注入扩展前调用该方法，且方法只在 token 为空时播种。
//  6. 子系统隔离：装扩展只开 yomitan-api（查词 API），绝不启动 Hibiki 互联/同步 server。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

/// 用内存 DB + prefsRepo 接线一个最小 AppModel，只驱动 yomitan 相关 getter/setter。
Future<AppModel> _prefsBackedAppModel(HibikiDatabase db) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir =
      Directory.systemTemp.createTempSync('hibiki_ext_yomitan_');
  addTearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  final AppModel appModel = _TestAppModel();
  return appModel
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}

void main() {
  test('disabled server → enables and starts, seeds token, returns true',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(db);
    // 绑临时端口（0=系统分配空闲端口），避免与真机 app 的 19633 冲突/端口占用抖动。
    await appModel.setYomitanApiPort(0);
    addTearDown(appModel.stopYomitanApiServer);

    expect(appModel.yomitanApiServerEnabled, isFalse);
    expect(appModel.yomitanApiKey, isEmpty);

    final bool ready =
        await appModel.ensureYomitanApiServerForBrowserExtension();

    expect(ready, isTrue, reason: '空闲端口应能成功启动');
    expect(appModel.yomitanApiServerEnabled, isTrue,
        reason: '安装扩展应默认开启 server');
    expect(appModel.yomitanApiKey, isNotEmpty,
        reason: 'token 为空时应播种，避免扩展无鉴权/展示不完整');
  });

  test('non-empty token is preserved (never overwritten → avoids 401)',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(db);
    // server 已启用 → 方法走「跳过不重启」早退分支，不绑 socket，纯确定性。
    await appModel.setYomitanApiKey('user-existing-token');
    await appModel.setYomitanApiServerEnabled(true);

    final bool ready =
        await appModel.ensureYomitanApiServerForBrowserExtension();

    expect(ready, isTrue);
    expect(appModel.yomitanApiKey, 'user-existing-token',
        reason: '已有 token 必须原样保留，否则踢掉扩展已配 token 造成 401');
    expect(appModel.yomitanApiServerEnabled, isTrue);
  });

  test('empty token seeded even when server already enabled, no restart',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(db);
    await appModel.setYomitanApiServerEnabled(true);
    expect(appModel.yomitanApiKey, isEmpty);

    final bool ready =
        await appModel.ensureYomitanApiServerForBrowserExtension();

    expect(ready, isTrue);
    expect(appModel.yomitanApiKey, isNotEmpty, reason: 'token 空则播种，非空才保留');
    expect(appModel.yomitanApiServerEnabled, isTrue);
  });

  // 用户诉求核心（TODO-1266 复核）：装扩展走 yomitan-api（查词 API），与「Hibiki 互联/
  // 同步」是两个独立子系统。装扩展只能开 yomitan-api server，绝不能连带启动互联/同步
  // server（HibikiSyncServerController）。本测试锁死子系统隔离，防止把「装扩展默认开」
  // 误绑到互联子系统。
  test('装扩展只开 yomitan-api server，绝不启动 Hibiki 互联/同步 server', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(db);
    // 绑临时端口（0=系统分配空闲端口），仅让 yomitan-api server 起在空闲端口。
    await appModel.setYomitanApiPort(0);
    addTearDown(appModel.stopYomitanApiServer);

    // 前置：互联/同步 server（HibikiSyncServerController）未启动。
    expect(appModel.syncServerController.isRunning, isFalse,
        reason: '前置：Hibiki 互联/同步 server 应处于未启动');

    final bool ready =
        await appModel.ensureYomitanApiServerForBrowserExtension();

    expect(ready, isTrue);
    // yomitan-api（查词 API）子系统已开——这是扩展真正要连的 server。
    expect(appModel.yomitanApiServerEnabled, isTrue,
        reason: '装扩展应开启 yomitan-api server（扩展查词走此 API）');
    // 互联/同步 server 全程未被触碰——装扩展与设备互联无关。
    expect(appModel.syncServerController.isRunning, isFalse,
        reason: '装扩展绝不能连带启动 Hibiki 互联/同步 server（两者是独立子系统）');
  });

  test('生产接线守卫：安装入口在注入扩展前自动开启 server，且只在 token 为空时播种', () async {
    // TODO-1266 复核：安装入口已从查词设置迁到桌面专属页 BrowserExtensionPage，接线契约不变。
    final File page =
        File('lib/src/pages/implementations/browser_extension_page.dart');
    expect(page.existsSync(), isTrue, reason: '浏览器扩展页文件应存在');
    final String pageSrc = page.readAsStringSync();
    final int callIdx =
        pageSrc.indexOf('ensureYomitanApiServerForBrowserExtension(');
    final int prepareIdx = pageSrc.indexOf('prepareBundledBrowserExtension(');
    expect(callIdx, greaterThanOrEqualTo(0),
        reason: '安装入口必须调用 ensureYomitanApiServerForBrowserExtension');
    expect(prepareIdx, greaterThanOrEqualTo(0));
    expect(callIdx, lessThan(prepareIdx),
        reason: '必须在解压/注入扩展（prepareBundledBrowserExtension）之前开启 server，'
            '保证注入扩展的 token 与 server 实际使用的 token 一致');

    final File model = File('lib/src/models/app_model.dart');
    final String modelSrc = model.readAsStringSync();
    final int methodIdx = modelSrc
        .indexOf('Future<bool> ensureYomitanApiServerForBrowserExtension');
    expect(methodIdx, greaterThanOrEqualTo(0));
    final String methodTail = modelSrc.substring(methodIdx);
    // 播种被 `yomitanApiKey.isEmpty` 门控 → 绝不覆盖已有 token。
    expect(methodTail.contains('yomitanApiKey.isEmpty'), isTrue,
        reason: 'token 播种必须以 yomitanApiKey.isEmpty 门控，绝不覆盖已有 token');
  });
}
