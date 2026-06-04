import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // AppModel.DefaultCacheManager 构造时经 path_provider 平台通道；单测里 mock。
  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_path_provider_synced');
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
  late Directory libraryDir; // == databaseDirectory，库目录
  late Directory stagingDir; // 模拟 orchestrator 的 _tempDir，解压落点
  late AppModel appModel;

  setUp(() async {
    db = _testDb();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    libraryDir = Directory.systemTemp.createTempSync('hibiki_synced_lib');
    stagingDir = Directory.systemTemp.createTempSync('hibiki_synced_staging');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
          prefsRepo: prefs, databaseDirectory: libraryDir);
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    for (final Directory d in <Directory>[libraryDir, stagingDir]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  /// 造一个 staging .db（模拟 importLocalAudioPackage 已解压到 stagingDir 的产物）。
  LocalAudioPackageContents stagedContents({
    required String displayName,
    bool enabled = true,
    List<LocalAudioSourcePref> sources = const <LocalAudioSourcePref>[],
  }) {
    final File dbFile = File(p.join(stagingDir.path, '$displayName.db'))
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    return LocalAudioPackageContents(
      dbFile: dbFile,
      displayName: displayName,
      enabled: enabled,
      sources: sources,
    );
  }

  test(
      'importSyncedLocalAudioDb rebuilds path under the library dir, '
      'never the staging path', () async {
    final LocalAudioPackageContents c = stagedContents(displayName: 'NHK');
    await appModel.importSyncedLocalAudioDb(c);

    final Iterable<AudioSourceConfig> local = appModel.audioSourceConfigs
        .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio);
    expect(local.length, 1, reason: '应新增一个 localAudio 配置项');
    final String path = local.single.path!;

    // (a) path 指向库目录下的 local_audio_*.db，而非 staging 源路径。
    expect(p.canonicalize(p.dirname(path)), p.canonicalize(libraryDir.path),
        reason: 'path 必须重建到库目录');
    expect(p.basename(path), matches(RegExp(r'^local_audio_\d+\.db$')));
    expect(p.canonicalize(path), isNot(p.canonicalize(c.dbFile.path)),
        reason: '绝不复用 staging 路径');
    expect(File(path).existsSync(), isTrue, reason: '库目录副本已落盘');
  });

  test(
      'importSyncedLocalAudioDb keeps audioSourceConfigs and localAudioDbs '
      'in sync (dual source of truth)', () async {
    await appModel.importSyncedLocalAudioDb(stagedContents(displayName: 'NHK'));

    final AudioSourceConfig cfg = appModel.audioSourceConfigs.singleWhere(
        (AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio);
    // (b) localAudioDbs 同步出现同一项，path 一致。
    expect(appModel.localAudioDbs.length, 1);
    expect(appModel.localAudioDbs.single.path, cfg.path);
    expect(appModel.localAudioDbs.single.displayName, 'NHK');
  });

  test('importSyncedLocalAudioDb dedups by displayName (silent skip)',
      () async {
    await appModel.importSyncedLocalAudioDb(stagedContents(displayName: 'NHK'));
    int localCount() => appModel.audioSourceConfigs
        .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio)
        .length;
    expect(localCount(), 1);

    // (c) 同名第二次调用被静默跳过，配置不重复增长。
    await appModel.importSyncedLocalAudioDb(stagedContents(displayName: 'NHK'));
    expect(localCount(), 1, reason: '同名不应重复增长');
    expect(appModel.localAudioDbs.length, 1);
  });

  test(
      'importSyncedLocalAudioDb bakes sub-source prefs in one write '
      '(I-2 single-write)', () async {
    final List<LocalAudioSourcePref> srcs = <LocalAudioSourcePref>[
      const LocalAudioSourcePref(name: 'nhk16', enabled: true),
      const LocalAudioSourcePref(name: 'forvo', enabled: false),
    ];
    await appModel.importSyncedLocalAudioDb(
        stagedContents(displayName: 'NHK', sources: srcs));

    // 子来源偏好随同步库一次写穿，落到 localAudioDbs（无需二次 setLocalAudioDbSources）。
    expect(appModel.localAudioDbs.single.sources, srcs);
  });

  test('importSyncedLocalAudioDb copies the staging .db (does not move it)',
      () async {
    // AppModel 用 copy，不 move：staging 源文件在 import 后仍存在（其删除是
    // orchestrator pull 分支的职责，见 sync_orchestrator_test 的 I-1 断言）。
    final LocalAudioPackageContents c = stagedContents(displayName: 'NHK');
    final String stagingPath = c.dbFile.path;
    await appModel.importSyncedLocalAudioDb(c);
    expect(File(stagingPath).existsSync(), isTrue,
        reason: 'AppModel 是拷贝语义，不动 staging 源文件');
  });
}
