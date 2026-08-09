import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 接线测试（补 Phase A code review 的 LOW 发现）：
///
/// [effectiveLookupSize] 纯函数已有单测，但「[AppModel] 把 independent 标志接到
/// 哪个宽/高键」这段接线之前无覆盖——接反参数（如把高度喂进 width）、写错偏好键、
/// 或默认值漏跟随 app 内共享值，纯函数测试仍全绿，只能真机发现。
///
/// 这里用真实 [PreferencesRepository] + [AppModel] 驱动 overlay/extension 两个
/// effective-size getter，断言：
/// 1. 默认（未解锁）严格跟随 app 内 [AppModel.popupMaxWidth]/[popupMaxHeight]；
/// 2. 解锁后用该场景自己的键，且宽/高不互串（用非对称值 700×900 抓接反参数）；
/// 3. 两个场景相互隔离（解锁 overlay 不影响 extension 跟随）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // AppModel 构造时 DefaultCacheManager 会经 path_provider 平台通道，单测 mock 掉。
  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;

  setUp(() async {
    db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = AppModel(testPlatformServices());
    appModel.wireLocalAudioForTesting(
      prefsRepo: prefs,
      databaseDirectory: Directory.systemTemp.createTempSync('lookup_size'),
    );
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  test('默认未解锁：overlay/extension 有效尺寸严格跟随 app 内共享值', () {
    final LookupSize shared =
        LookupSize(appModel.popupMaxWidth, appModel.popupMaxHeight);
    expect(appModel.overlayLookupIndependentSize, isFalse);
    expect(appModel.extensionPopupIndependentSize, isFalse);
    expect(appModel.overlayLookupEffectiveSize, shared);
    expect(appModel.extensionPopupEffectiveSize, shared);
  });

  test('解锁 overlay 后用自身非对称宽高（700×900），宽高不互串', () async {
    await prefs.setPref('overlay_lookup_independent_size', true);
    await prefs.setPref('overlay_lookup_max_width', 700.0);
    await prefs.setPref('overlay_lookup_max_height', 900.0);

    expect(appModel.overlayLookupIndependentSize, isTrue);
    // 若 effective getter 把 sceneHeight 喂进了 width（接反参数），这里会拿到 900×700。
    expect(appModel.overlayLookupEffectiveSize, const LookupSize(700.0, 900.0));

    // 场景隔离：extension 仍未解锁，继续跟随 app 内共享值。
    final LookupSize shared =
        LookupSize(appModel.popupMaxWidth, appModel.popupMaxHeight);
    expect(appModel.extensionPopupEffectiveSize, shared);
  });

  test('解锁 extension 后用自身非对称宽高（500×650），且不影响 overlay', () async {
    await prefs.setPref('extension_popup_independent_size', true);
    await prefs.setPref('extension_popup_max_width', 500.0);
    await prefs.setPref('extension_popup_max_height', 650.0);

    expect(appModel.extensionPopupIndependentSize, isTrue);
    expect(
        appModel.extensionPopupEffectiveSize, const LookupSize(500.0, 650.0));

    // overlay 仍跟随共享值。
    final LookupSize shared =
        LookupSize(appModel.popupMaxWidth, appModel.popupMaxHeight);
    expect(appModel.overlayLookupEffectiveSize, shared);
  });

  test('已写入独立宽高但开关关闭时，有效尺寸仍跟随共享值（不误用旧独立值）', () async {
    // 先写独立值但保持 independent=false。
    await prefs.setPref('overlay_lookup_max_width', 1200.0);
    await prefs.setPref('overlay_lookup_max_height', 1500.0);
    expect(appModel.overlayLookupIndependentSize, isFalse);

    final LookupSize shared =
        LookupSize(appModel.popupMaxWidth, appModel.popupMaxHeight);
    expect(appModel.overlayLookupEffectiveSize, shared,
        reason: '关闭独立开关时必须跟随 app 内，忽略已存在的独立宽高');
  });
}
