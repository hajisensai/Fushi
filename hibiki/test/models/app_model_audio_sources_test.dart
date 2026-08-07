import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/local_audio_db.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart';

import '../helpers/test_platform_services.dart';

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

/// 写一个「可用」的本地音频源库（entries + android schema + 一行音频字节），让
/// [AppModel.importLocalAudioDbFile] → [LocalAudioManager.importFile] 的 BUG-779
/// 内容校验通过。旧桩写 [1,2,3] 假字节现在会被 isUsableAudioSource 正确拒绝，故
/// 这些导入用例的 fixture 统一改用真实最小音频库（用例意图不变）。
void _writeValidAudioDb(String path) {
  // 幂等：同名调用（如按 displayName 去重的用例会二次造同路径库）先删旧文件，
  // 复刻旧桩 writeAsBytesSync 的覆盖语义，避免在已建表的库上重复 CREATE TABLE。
  final File dbFile = File(path);
  if (dbFile.existsSync()) dbFile.deleteSync();
  final Database sdb = sqlite3.open(path);
  try {
    sdb.execute('CREATE TABLE entries '
        '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
    sdb.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    sdb.execute("INSERT INTO entries VALUES ('猫','ねこ','neko.mp3','forvo')");
    final PreparedStatement stmt =
        sdb.prepare('INSERT INTO android (file, source, data) VALUES (?,?,?)');
    stmt.execute(<Object?>[
      'neko.mp3',
      'forvo',
      Uint8List.fromList(<int>[1, 2, 3])
    ]);
    stmt.dispose();
  } finally {
    sdb.dispose();
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

  late FushiDatabase db;
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
    srcA = File('${src.path}/a.db');
    srcB = File('${src.path}/b.db');
    _writeValidAudioDb(srcA.path);
    _writeValidAudioDb(srcB.path);
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    // 绑定库列表会后台补查询索引（LocalAudioDb.ensureIndexes，持 readWrite
    // 句柄）；Windows 上删被打开的文件是 errno 32，删临时目录前先排空在途任务。
    await LocalAudioDb.waitForPendingIndexing();
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

  test('local db enabled survives a setAudioSourceConfigs round-trip',
      () async {
    final LocalAudioDbEntry a =
        await appModel.importLocalAudioDbFile(srcA.path, displayName: 'A');
    // persist the db as enabled
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: true),
    ]);
    // open then close the dialog: read the projection and save it back
    final List<AudioSourceConfig> projected = appModel.audioSourceConfigs;
    await appModel.setAudioSourceConfigs(projected);
    // the db's real per-db enabled must be preserved across the round-trip
    expect(appModel.localAudioDbs.single.enabled, isTrue);
  });

  test('enabledAudioSourceConfigs gates local audio by per-db enabled only',
      () async {
    final LocalAudioDbEntry a =
        await appModel.importLocalAudioDbFile(srcA.path, displayName: 'A');
    final LocalAudioDbEntry b =
        await appModel.importLocalAudioDbFile(srcB.path, displayName: 'B');
    await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'A', path: a.path, enabled: true),
      AudioSourceConfig.localAudio(label: 'B', path: b.path, enabled: false),
    ]);
    final List<AudioSourceConfig> enabled = appModel.enabledAudioSourceConfigs;
    final Iterable<AudioSourceConfig> localEnabled = enabled
        .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio);
    expect(localEnabled.length, 1);
    expect(localEnabled.single.path, a.path);
  });

  /// Guards the BUG-483 fix: "添加本地音频数据库" must support referencing the
  /// original file instead of unconditionally copying it into AppData. The
  /// manager-level behaviour (reference import + external-path deletion
  /// safety) is covered behaviourally in local_audio_manager_test.dart; the
  /// AppModel/UI/schema threading below cannot be mounted in a host unit
  /// test, so it stays a source-level guard (moved from
  /// test/tools/local_audio_reference_guard_test.dart).
  group('local audio reference-original contract (BUG-483)', () {
    final String appModel =
        File('lib/src/models/app_model.dart').readAsStringSync();
    final String dialog = File(
            'lib/src/pages/implementations/dictionary_settings_dialog_page.dart')
        .readAsStringSync();
    final String schema =
        File('lib/src/settings/settings_schema_lookup.dart').readAsStringSync();

    test('reference flag is threaded through app model and UI', () {
      expect(appModel, contains('bool reference = false'),
          reason: 'AppModel.importLocalAudioDbFile must forward reference.');
      expect(appModel, contains('reference: reference'),
          reason: 'AppModel must pass reference into the manager.');
      expect(dialog, contains('isDesktopPlatform'),
          reason: 'The reference toggle must be desktop-gated.');
      expect(dialog, contains('local_audio_reference_original'),
          reason: 'The dialog must surface the reference toggle label.');
      expect(dialog, contains('Function(bool reference)?'),
          reason: 'onPickLocalDb must receive the reference flag.');
      expect(schema, contains('reference: reference'),
          reason: 'The lookup settings wiring must forward the flag.');
    });
  });
}
