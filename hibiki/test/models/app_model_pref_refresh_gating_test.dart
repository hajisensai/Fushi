import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// 行为测试（TODO-855）：warm-reuse 弹窗只在 profile/pref 真正变化时刷新 prefCache。
///
/// [AppModel.refreshPrefCacheIfChanged] 是 :popup 进程每次外查词的热路径决策点：
/// 先做一次廉价的单行 `prefs_version` DB 读，仅当版本与上次对账的水位不同才跑全量
/// [AppModel.refreshPrefCache]。本测试用一个记录刷新次数的 AppModel 子类驱动该决策，
/// 断言「无变化 0 次刷新、版本变化恰 1 次刷新」。
class _RecordingAppModel extends AppModel {
  _RecordingAppModel() : super(testPlatformServices());

  int refreshCount = 0;

  // 真 refreshPrefCache 会触碰未初始化的 mediaSources/themeNotifier 等子系统，
  // host 单测无法真实驱动；这里只计数。refreshPrefCacheIfChanged 在调用本方法后
  // 会自行把水位推进到刚读到的 dbVersion，故水位推进不依赖本方法体。
  @override
  Future<void> refreshPrefCache() async {
    refreshCount++;
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // AppModel 的 DefaultCacheManager 字段在构造时就异步打开缓存目录，会经
  // path_provider 平台通道；单测里没有插件实现，mock 一个临时目录即可。
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

  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late _RecordingAppModel appModel;

  setUp(() async {
    db = HibikiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = _RecordingAppModel();
    appModel.wireLocalAudioForTesting(
      prefsRepo: prefs,
      databaseDirectory: Directory.systemTemp.createTempSync('todo855'),
    );
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  test('first call primes the watermark (refreshes once)', () async {
    expect(appModel.refreshCount, 0);
    await appModel.refreshPrefCacheIfChanged();
    // -1 (unprimed) != 0 (fresh DB) -> reconciles once.
    expect(appModel.refreshCount, 1);
  });

  test('no profile/pref change -> zero further refreshes', () async {
    await appModel.refreshPrefCacheIfChanged(); // primes -> 1
    expect(appModel.refreshCount, 1);

    // Several lookups with NOTHING changed in the DB: no extra reloads.
    await appModel.refreshPrefCacheIfChanged();
    await appModel.refreshPrefCacheIfChanged();
    await appModel.refreshPrefCacheIfChanged();
    expect(appModel.refreshCount, 1,
        reason: 'warm-reuse lookups must not reload when prefs are unchanged');
  });

  test('a prefs_version bump triggers exactly one refresh', () async {
    await appModel.refreshPrefCacheIfChanged(); // primes -> 1
    expect(appModel.refreshCount, 1);

    // Simulate the MAIN app mutating a preference (bumps prefs_version in DB).
    await prefs.setPref('font_size', '24');

    await appModel.refreshPrefCacheIfChanged();
    expect(appModel.refreshCount, 2,
        reason: 'a real pref change must trigger exactly one reload');

    // Still no further change -> no further reload.
    await appModel.refreshPrefCacheIfChanged();
    expect(appModel.refreshCount, 2);
  });

  test('a profile-switch-style direct DB version bump is detected', () async {
    await appModel.refreshPrefCacheIfChanged(); // primes -> 1
    expect(appModel.refreshCount, 1);

    // applyProfile writes the version straight to the DB row (not via prefs).
    await db.setPref(PreferencesRepository.prefsVersionKey, '5');

    await appModel.refreshPrefCacheIfChanged();
    expect(appModel.refreshCount, 2,
        reason: 'profile switch (direct DB version bump) must be detected');
  });
}
