import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/desktop_lookup_startup.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-4846：全局查词覆盖窗（查词卡 surface）不跟「查词」模块走。
///
/// 查词模块只关查词页入口、查词能力全留（用户拍板）。覆盖窗此前按查词模块门控，
/// 首启向导选「只看媒体」或手动关掉查词页的用户，galgame 游戏内点词不弹卡
/// （`lookupText` 在覆盖窗未起时直接返回 false）、桌面应用外悬浮球的「应用外
/// 查词」「截屏识字」也一起消失。现在桌面启动链 [startDesktopLookupSurfaces]
/// 只按平台能力起覆盖窗。
///
/// 控制器是进程级单例、`start` 是单向闩，所以本文件只放这一条用例。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('查词模块关、games 开：启动链照样起覆盖窗，galgame 查词有卡可弹', () async {
    GlobalLookupController.platformOverride = true;
    // galgame 台词浮窗本身不是这里要钉的东西（它随 games 模块），关掉免得
    // 拉起它的 native 通道。
    GalHookTextOverlayChannel.platformOverride = false;
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
      'fushi_lookup_module_independence',
    );
    addTearDown(() async {
      GlobalLookupController.platformOverride = null;
      GalHookTextOverlayChannel.platformOverride = null;
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
    await prefs.setModuleEnabled(ModuleId.games, true);
    expect(appModel.moduleVisibility.isEnabled(ModuleId.lookup), isFalse);

    await startDesktopLookupSurfaces(appModel);

    final GlobalLookupController controller = GlobalLookupController.instance;
    expect(
      controller.isAvailable,
      isTrue,
      reason: '查词模块只关查词页；覆盖窗是 galgame / 应用外球共用的查词卡',
    );
    expect(overlayCalls.where((String m) => m == 'prepare'), hasLength(1));

    // 模块开关再变也不影响覆盖窗：既不重复建窗，也不因关模块而停。
    await appModel.setModuleEnabled(ModuleId.lookup, true);
    await appModel.setModuleEnabled(ModuleId.lookup, false);
    await pumpEventQueue();
    expect(controller.isAvailable, isTrue);
    expect(overlayCalls.where((String m) => m == 'prepare'), hasLength(1));
  });
}
