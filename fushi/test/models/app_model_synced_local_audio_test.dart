import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi/src/utils/misc/local_audio_db.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
}

/// 写一个「可用」的本地音频源库（entries + android schema + 一行音频字节），让
/// [AppModel.importSyncedLocalAudioDb] → [LocalAudioManager.importFile] 的 BUG-779
/// 内容校验通过。旧桩写 [1,2,3,4] 假字节现在会被 isUsableAudioSource 正确拒绝，故
/// 同步库 fixture 改用真实最小音频库（用例意图=路径重建/双真相源/去重 不变）。
void _writeValidAudioDb(String path) {
  // 幂等：同名调用（如按 displayName 去重的用例会二次造同路径库）先删旧文件，
  // 复刻旧桩 writeAsBytesSync 的覆盖语义，避免在已建表的库上重复 CREATE TABLE。
  final File dbFile = File(path);
  if (dbFile.existsSync()) dbFile.deleteSync();
  final Database sdb = sqlite3.open(path);
  try {
    sdb.execute(
      'CREATE TABLE entries '
      '(expression TEXT, reading TEXT, file TEXT, source TEXT)',
    );
    sdb.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    sdb.execute("INSERT INTO entries VALUES ('猫','ねこ','neko.mp3','nhk16')");
    final PreparedStatement stmt = sdb.prepare(
      'INSERT INTO android (file, source, data) VALUES (?,?,?)',
    );
    stmt.execute(<Object?>[
      'neko.mp3',
      'nhk16',
      Uint8List.fromList(<int>[1, 2, 3]),
    ]);
    stmt.dispose();
  } finally {
    sdb.dispose();
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // AppModel.DefaultCacheManager 构造时经 path_provider 平台通道；单测里 mock。
  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_path_provider_synced',
    );
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
  late Directory libraryDir; // == databaseDirectory，库目录
  late Directory stagingDir; // 模拟 orchestrator 的 _tempDir，解压落点
  late AppModel appModel;

  setUp(() async {
    db = _testDb();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    libraryDir = Directory.systemTemp.createTempSync('fushi_synced_lib');
    stagingDir = Directory.systemTemp.createTempSync('fushi_synced_staging');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: libraryDir,
      );
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    // 绑定库列表会后台补查询索引（LocalAudioDb.ensureIndexes，持 readWrite
    // 句柄）；Windows 上删被打开的文件是 errno 32，删临时目录前先排空在途任务。
    await LocalAudioDb.waitForPendingIndexing();
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
    final File dbFile = File(p.join(stagingDir.path, '$displayName.db'));
    _writeValidAudioDb(dbFile.path);
    return LocalAudioPackageContents(
      dbFile: dbFile,
      displayName: displayName,
      enabled: enabled,
      sources: sources,
    );
  }

  test('importSyncedLocalAudioDb rebuilds path under the library dir, '
      'never the staging path', () async {
    final LocalAudioPackageContents c = stagedContents(displayName: 'NHK');
    await appModel.importSyncedLocalAudioDb(c);

    final Iterable<AudioSourceConfig> local = appModel.audioSourceConfigs.where(
      (AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio,
    );
    expect(local.length, 1, reason: '应新增一个 localAudio 配置项');
    final String path = local.single.path!;

    // (a) path 指向库目录下的 local_audio_*.db，而非 staging 源路径。
    expect(
      p.canonicalize(p.dirname(path)),
      p.canonicalize(libraryDir.path),
      reason: 'path 必须重建到库目录',
    );
    expect(p.basename(path), matches(RegExp(r'^local_audio_\d+\.db$')));
    expect(
      p.canonicalize(path),
      isNot(p.canonicalize(c.dbFile.path)),
      reason: '绝不复用 staging 路径',
    );
    expect(File(path).existsSync(), isTrue, reason: '库目录副本已落盘');
  });

  test('importSyncedLocalAudioDb keeps audioSourceConfigs and localAudioDbs '
      'in sync (dual source of truth)', () async {
    await appModel.importSyncedLocalAudioDb(stagedContents(displayName: 'NHK'));

    final AudioSourceConfig cfg = appModel.audioSourceConfigs.singleWhere(
      (AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio,
    );
    // (b) localAudioDbs 同步出现同一项，path 一致。
    expect(appModel.localAudioDbs.length, 1);
    expect(appModel.localAudioDbs.single.path, cfg.path);
    expect(appModel.localAudioDbs.single.displayName, 'NHK');
  });

  test(
    'importSyncedLocalAudioDb dedups by displayName (silent skip)',
    () async {
      await appModel.importSyncedLocalAudioDb(
        stagedContents(displayName: 'NHK'),
      );
      int localCount() => appModel.audioSourceConfigs
          .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio)
          .length;
      expect(localCount(), 1);

      // (c) 同名第二次调用被静默跳过，配置不重复增长。
      await appModel.importSyncedLocalAudioDb(
        stagedContents(displayName: 'NHK'),
      );
      expect(localCount(), 1, reason: '同名不应重复增长');
      expect(appModel.localAudioDbs.length, 1);
    },
  );

  test('BUG-3702: same-name entry whose DB is not on this device is re-pointed '
      'in place (order / enabled / sub-sources kept), not skipped', () async {
    // 导入别的设备的配置方案后的样子：同名本地库条目在，路径是那台设备的内部副本
    // （按文件名归一到本机库目录后也找不到文件），排在一条远端源之后、关着、带子来源偏好。
    const String foreignPath =
        r'C:\Users\other\AppData\Roaming\Fushi\local_audio_1783304412795.db';
    const List<LocalAudioSourcePref> keptSources = <LocalAudioSourcePref>[
      LocalAudioSourcePref(name: 'forvo', enabled: true),
      LocalAudioSourcePref(name: 'nhk16', enabled: false),
    ];
    await prefs.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.remoteAudio(url: 'https://example.test/{term}'),
      AudioSourceConfig.localAudio(
        label: 'NHK',
        path: foreignPath,
        enabled: false,
      ),
    ]);
    await prefs.setPref(
      'local_audio_dbs',
      jsonEncode(<Map<String, dynamic>>[
        const LocalAudioDbEntry(
          path: foreignPath,
          displayName: 'NHK',
          enabled: false,
          sources: keptSources,
        ).toJson(),
      ]),
    );
    expect(
      await appModel.isLocalAudioDbAvailable(foreignPath),
      isFalse,
      reason: '前置：这条引用在本机确实不可用',
    );
    final List<AudioSourceConfig> before = appModel.audioSourceConfigs;

    await appModel.importSyncedLocalAudioDb(
      stagedContents(
        displayName: 'NHK',
        sources: const <LocalAudioSourcePref>[
          LocalAudioSourcePref(name: 'nhk16', enabled: true),
        ],
      ),
    );

    final List<AudioSourceConfig> after = appModel.audioSourceConfigs;
    expect(after.length, before.length, reason: '原位改指，不追加同名新源');
    final int index = before.indexWhere(
      (AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio,
    );
    final AudioSourceConfig repointed = after[index];
    expect(repointed.kind, AudioSourceKind.localAudio, reason: '在源列表里的位置不变');
    expect(repointed.displayLabel, 'NHK');
    expect(repointed.enabled, isFalse, reason: '保留用户的开关');
    expect(
      p.canonicalize(p.dirname(repointed.path!)),
      p.canonicalize(libraryDir.path),
    );
    expect(
      await appModel.isLocalAudioDbAvailable(repointed.path!),
      isTrue,
      reason: '改指后本机能找到这份库',
    );
    expect(
      appModel.localAudioDbs.single.path,
      repointed.path,
      reason: 'audio_source_configs 与 local_audio_dbs 双写一致',
    );
    expect(
      appModel.localAudioDbs.single.sources,
      keptSources,
      reason: '保留该条目原有的子来源偏好，不被同步包里的覆盖',
    );
  });

  test('importSyncedLocalAudioDb bakes sub-source prefs in one write '
      '(I-2 single-write)', () async {
    final List<LocalAudioSourcePref> srcs = <LocalAudioSourcePref>[
      const LocalAudioSourcePref(name: 'nhk16', enabled: true),
      const LocalAudioSourcePref(name: 'forvo', enabled: false),
    ];
    await appModel.importSyncedLocalAudioDb(
      stagedContents(displayName: 'NHK', sources: srcs),
    );

    // 子来源偏好随同步库一次写穿，落到 localAudioDbs（无需二次 setLocalAudioDbSources）。
    expect(appModel.localAudioDbs.single.sources, srcs);
  });

  test(
    'importSyncedLocalAudioDb copies the staging .db (does not move it)',
    () async {
      // AppModel 用 copy，不 move：staging 源文件在 import 后仍存在（其删除是
      // orchestrator pull 分支的职责，见 sync_orchestrator_test 的 I-1 断言）。
      final LocalAudioPackageContents c = stagedContents(displayName: 'NHK');
      final String stagingPath = c.dbFile.path;
      await appModel.importSyncedLocalAudioDb(c);
      expect(
        File(stagingPath).existsSync(),
        isTrue,
        reason: 'AppModel 是拷贝语义，不动 staging 源文件',
      );
    },
  );
}
