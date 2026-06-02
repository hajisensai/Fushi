import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
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
  late Directory storeDir;
  late AppModel appModel;
  late File srcA;
  late File srcB;

  setUp(() async {
    db = _testDb();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_app_model_audio');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);

    final Directory src =
        Directory.systemTemp.createTempSync('hibiki_app_model_audio_src');
    srcA = File('${src.path}/a.db')..writeAsBytesSync(<int>[1, 2, 3]);
    srcB = File('${src.path}/b.db')..writeAsBytesSync(<int>[4, 5, 6]);
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
    if (srcA.parent.existsSync()) {
      srcA.parent.deleteSync(recursive: true);
    }
  });

  test('setAudioSourceConfigs deletes files of removed local audio dbs',
      () async {
    final LocalAudioDbEntry a =
        await appModel.importLocalAudioDbFile(srcA.path, displayName: 'A');
    final LocalAudioDbEntry b =
        await appModel.importLocalAudioDbFile(srcB.path, displayName: 'B');
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: true),
      AudioSourceConfig.localAudio(label: 'B', path: b.path, enabled: true),
    ]);
    expect(File(a.path).existsSync(), isTrue);
    expect(File(b.path).existsSync(), isTrue);

    // remove B
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: true),
    ]);
    expect(File(a.path).existsSync(), isTrue);
    expect(File(b.path).existsSync(), isFalse);
  });

  test('setAudioSourceConfigs does NOT auto-toggle localAudioEnabled',
      () async {
    await appModel.setLocalAudioEnabled(true);
    final LocalAudioDbEntry a =
        await appModel.importLocalAudioDbFile(srcA.path, displayName: 'A');
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: false),
    ]);
    // 显式总开关保留，不从 entry 状态派生。
    expect(appModel.localAudioEnabled, isTrue);
  });

  test('local db enabled survives a setAudioSourceConfigs round-trip while master is OFF',
      () async {
    final LocalAudioDbEntry a =
        await appModel.importLocalAudioDbFile(srcA.path, displayName: 'A');
    // persist the db as enabled
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: true),
    ]);
    // user turns the global master switch OFF
    await appModel.setLocalAudioEnabled(false);
    // user merely opens then closes the dialog: read the projection, save it back
    final List<AudioSourceConfig> projected = appModel.audioSourceConfigs;
    await appModel.setAudioSourceConfigs(projected);
    // the db's real per-db enabled must be preserved (not wiped by master-off projection)
    expect(appModel.localAudioDbs.single.enabled, isTrue);
  });
}
