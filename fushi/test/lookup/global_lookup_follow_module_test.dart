import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 全局查词覆盖窗跟随查词模块（BUG-2793 审查第 3 条）：此前覆盖窗只在启动时按
/// 模块开关判一次，会话中途打开查词模块后桌面悬浮球「应用外查词」按钮出现、点了
/// 却什么都不发生（覆盖窗要下次启动才起）。
///
/// 控制器是进程级单例、`start` 是单向闩，所以本文件只放这一条用例。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('中途打开查词模块即沿同一条 start 起覆盖窗；再通知不重复建窗，关模块不停', () async {
    GlobalLookupController.platformOverride = true;
    final List<String> overlayCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(FushiChannels.globalLookup, (
      MethodCall call,
    ) async {
      overlayCalls.add(call.method);
      return null;
    });
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_lookup_follow',
    );
    addTearDown(() async {
      GlobalLookupController.platformOverride = null;
      messenger.setMockMethodCallHandler(FushiChannels.globalLookup, null);
      await db.close();
      if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
    });
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir)
      ..wireDatabaseForTesting(db);
    await prefs.setModuleEnabled(ModuleId.lookup, false);

    final GlobalLookupController controller = GlobalLookupController.instance;
    await controller.followLookupModule(appModel);
    expect(controller.isAvailable, isFalse, reason: '模块关着不装钩子、不建窗');
    expect(overlayCalls, isNot(contains('prepare')));

    await appModel.setModuleEnabled(ModuleId.lookup, true);
    await pumpEventQueue();
    expect(controller.isAvailable, isTrue, reason: '打开模块当场起覆盖窗，不等下次启动');
    expect(overlayCalls.where((String m) => m == 'prepare'), hasLength(1));

    // 关模块不停（「不切断进行中的任务」）；再打开也不重复建窗。
    await appModel.setModuleEnabled(ModuleId.lookup, false);
    await pumpEventQueue();
    expect(controller.isAvailable, isTrue);
    await appModel.setModuleEnabled(ModuleId.lookup, true);
    await pumpEventQueue();
    expect(overlayCalls.where((String m) => m == 'prepare'), hasLength(1));
  });
}
