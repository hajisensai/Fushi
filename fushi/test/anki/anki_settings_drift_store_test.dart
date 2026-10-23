import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_settings_drift_store.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync/temp_dir_cleanup.dart';

/// 反馈 fiwDIpFep7：Anki 制卡设置从 SharedPreferences（每进程 / isolate 一份内存
/// 缓存）迁进 Drift `preferences` 表，让主 app、Android `:popup` 独立进程与悬浮
/// 词典 engine 读写同一行。这里钉住：跨连接立即可见、一次性迁移的幂等与并发、
/// 切旧 Profile 不删设置、备份不带出 apiKey、SP 默认实现行为不变。
class _Repo extends BaseAnkiRepository {
  _Repo({super.settingsStore});

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('n/a');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => const MineOutcome.success();

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

Future<int> _prefsVersion(FushiDatabase db) async {
  final String? raw = await db.getPref(FushiDatabase.prefsVersionKey);
  return raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
}

Future<Directory> _tempDir(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  return dir;
}

String _settingsJson({required String deck, String apiKey = ''}) => jsonEncode(
  AnkiSettings(selectedDeckName: deck, ankiConnectApiKey: apiKey).toJson(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    BaseAnkiRepository.defaultSettingsStore =
        const SharedPreferencesAnkiSettingsStore();
  });

  group('DriftAnkiSettingsStore', () {
    test('两个连接打开同一库文件：A 写，B 下一次读立刻是新值', () async {
      final Directory dir = await _tempDir('anki_store_xproc_');
      final FushiDatabase a = FushiDatabase(dir.path);
      final FushiDatabase b = FushiDatabase(dir.path);
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      final _Repo repoA = _Repo(settingsStore: DriftAnkiSettingsStore(() => a));
      final _Repo repoB = _Repo(settingsStore: DriftAnkiSettingsStore(() => b));

      await repoA.saveSettings(const AnkiSettings(selectedDeckName: 'Old'));
      expect((await repoB.loadSettings()).selectedDeckName, 'Old');

      final int before = await _prefsVersion(b);
      await repoA.saveSettings(const AnkiSettings(selectedDeckName: 'New'));
      expect(
        (await repoB.loadSettings()).selectedDeckName,
        'New',
        reason: 'B 不得读到自己的旧缓存——这正是 SP 存储的 bug',
      );
      expect(
        await _prefsVersion(b),
        before + 1,
        reason: '写入要递增跨进程版本号，常驻 popup 才知道去失效 Anki 派生状态',
      );
    });

    test('载入期迁移在 Drift 存储上照样回写', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final DriftAnkiSettingsStore store = DriftAnkiSettingsStore(() => db);
      await store.write(
        jsonEncode(<String, dynamic>{
          'fieldMappings': <String, String>{
            'SentenceAudio': '{sasayaki-audio}',
          },
        }),
      );

      final AnkiSettings loaded = await _Repo(
        settingsStore: store,
      ).loadSettings();

      expect(loaded.fieldMappings['SentenceAudio'], '{sentence-audio}');
      expect(
        await store.read(),
        isNot(contains('{sasayaki-audio}')),
        reason: '别名改写必须落回新存储，而不是只改内存',
      );
    });

    test('装配点：实例没注入时读写走 defaultSettingsStore', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      BaseAnkiRepository.defaultSettingsStore = DriftAnkiSettingsStore(
        () => db,
      );

      await _Repo().saveSettings(const AnkiSettings(selectedDeckName: 'Via'));

      expect(
        PrefCodec.decode<String?>(
          (await db.getPref(kAnkiSettingsPrefKey))!,
          null,
        ),
        contains('"selectedDeckName":"Via"'),
      );
    });
  });

  group('migrateAnkiSettingsFromSharedPreferences', () {
    test('连跑两次只写一次，值等于 SP 旧值，SP 原样保留', () async {
      final String legacy = _settingsJson(deck: 'Mined', apiKey: 'k');
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fushi_anki_settings': legacy,
      });
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final int v0 = await _prefsVersion(db);

      expect(await migrateAnkiSettingsFromSharedPreferences(db), isTrue);
      expect(await migrateAnkiSettingsFromSharedPreferences(db), isFalse);

      expect(await DriftAnkiSettingsStore(() => db).read(), legacy);
      expect(await _prefsVersion(db), v0 + 1, reason: '只落地一次 → 只递增一次');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('fushi_anki_settings'),
        legacy,
        reason: '迁移绝不改 / 删 SP（:popup 进程写 SP 会盖掉主进程的文件）',
      );
    });

    test('Drift 已有该行：不读 SP、不覆盖', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fushi_anki_settings': _settingsJson(deck: 'StaleSp'),
      });
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final DriftAnkiSettingsStore store = DriftAnkiSettingsStore(() => db);
      final String current = _settingsJson(deck: 'Current');
      await store.write(current);

      expect(await migrateAnkiSettingsFromSharedPreferences(db), isFalse);
      expect(await store.read(), current);
    });

    test('只有 Hibiki 时代旧键也能迁，且旧键不被删除', () async {
      final String legacy = _settingsJson(deck: 'Hoshi');
      SharedPreferences.setMockInitialValues(<String, Object>{
        AnkiSettingsSharedPreferencesKeys.legacySettingsKey: legacy,
      });
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);

      expect(await migrateAnkiSettingsFromSharedPreferences(db), isTrue);
      expect(await DriftAnkiSettingsStore(() => db).read(), legacy);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AnkiSettingsSharedPreferencesKeys.legacySettingsKey),
        legacy,
      );
    });

    test('SP 里什么都没有：不写行、不动版本号', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final int v0 = await _prefsVersion(db);

      expect(await migrateAnkiSettingsFromSharedPreferences(db), isFalse);
      expect(await db.getPref(kAnkiSettingsPrefKey), isNull);
      expect(await _prefsVersion(db), v0);
    });

    test('两个连接（模拟主进程与 :popup 首启）并发迁移：恰好落地一次', () async {
      final String legacy = _settingsJson(deck: 'Race', apiKey: 'k');
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fushi_anki_settings': legacy,
      });
      final Directory dir = await _tempDir('anki_store_race_');
      final FushiDatabase a = FushiDatabase(dir.path);
      final FushiDatabase b = FushiDatabase(dir.path);
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      // 先各自开库（触发迁移阶梯 / PRAGMA），让并发真的落在迁移写上。
      final int v0 = await _prefsVersion(a);
      await _prefsVersion(b);

      final List<bool> landed = await Future.wait(<Future<bool>>[
        migrateAnkiSettingsFromSharedPreferences(a),
        migrateAnkiSettingsFromSharedPreferences(b),
      ]);

      expect(landed.where((bool w) => w).length, 1, reason: '$landed');
      expect(await DriftAnkiSettingsStore(() => b).read(), legacy);
      expect(await _prefsVersion(a), v0 + 1);
    });
  });

  group('insertPrefIfAbsent', () {
    test('已有行时不写也不递增版本号；缺行时写并递增', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final int v0 = await _prefsVersion(db);

      expect(await db.insertPrefIfAbsent('k', 's:first'), isTrue);
      expect(await _prefsVersion(db), v0 + 1);
      expect(await db.insertPrefIfAbsent('k', 's:second'), isFalse);
      expect(await db.getPref('k'), 's:first');
      expect(await _prefsVersion(db), v0 + 1);
    });
  });

  group('Profile / 备份边界', () {
    test('切到迁移前建的旧 Profile：anki_settings 行不被剪掉，非快照字段保留', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final _Repo anki = _Repo(settingsStore: DriftAnkiSettingsStore(() => db));
      final ProfileRepository profiles = ProfileRepository(db, anki);

      // 旧 Profile：快照时库里还没有 anki_settings 行（迁移前的形态）。
      final int oldId = await profiles.createProfile('Old');
      await profiles.snapshotCurrentSettings(oldId);
      expect(
        (await db.getProfileSettings(
          oldId,
        )).where((ProfileSettingRow r) => r.key == kAnkiSettingsPrefKey),
        isEmpty,
      );

      // 迁移后用户配好的连接（apiKey / host 不随 Profile 走）。
      await anki.saveSettings(
        const AnkiSettings(
          selectedDeckName: 'Current',
          ankiConnectHost: '10.0.0.5',
          ankiConnectApiKey: 'secret',
        ),
      );

      await profiles.applyProfile(oldId);

      expect(
        await db.getPref(kAnkiSettingsPrefKey),
        isNotNull,
        reason: '快照里没有这个键 ≠ 应该删掉它',
      );
      final AnkiSettings after = await anki.loadSettings();
      expect(after.ankiConnectHost, '10.0.0.5');
      expect(after.ankiConnectApiKey, 'secret');
    });

    test('anki_settings 是设备本地 + 凭据：不进 Profile 快照 / 备份', () {
      expect(ProfileKeys.isExcludedPref(kAnkiSettingsPrefKey), isTrue);
      expect(
        SyncRepository.deviceLocalPrefKeys,
        contains(kAnkiSettingsPrefKey),
      );
      expect(
        PrefRedactionPolicy.isDeviceLocalOrCredential(kAnkiSettingsPrefKey),
        isTrue,
      );
    });

    test('备份导出剔除 anki_settings（含 AnkiConnect apiKey）', () async {
      final Directory srcDir = await _tempDir('anki_store_bk_src_');
      final FushiDatabase srcDb = FushiDatabase(srcDir.path);
      await DriftAnkiSettingsStore(
        () => srcDb,
      ).write(_settingsJson(deck: 'D', apiKey: 'SECRET-KEY'));
      await srcDb.setPref('reader_font_size', '18');

      final Directory zipDir = await _tempDir('anki_store_bk_zip_');
      final String zipPath = '${zipDir.path}/b.zip';
      await BackupService(
        db: srcDb,
        dbDirectory: srcDir.path,
        appVersion: '1.0.0',
      ).createBackup(zipPath);
      await srcDb.close();

      final Directory dstDir = await _tempDir('anki_store_bk_dst_');
      await BackupRestoreService.restoreBackup(
        dbDirectory: dstDir.path,
        zipPath: zipPath,
      );
      final FushiDatabase dstDb = FushiDatabase(dstDir.path);
      addTearDown(dstDb.close);
      expect(await dstDb.getPref(kAnkiSettingsPrefKey), isNull);
      expect(
        await dstDb.getPref('reader_font_size'),
        '18',
        reason: '普通设置照常随备份走（剔除不是整表清空）',
      );
    });
  });

  group('SharedPreferences 默认实现（无 Drift 宿主 / 测试）行为不变', () {
    test('默认装配点是 SP；读写 fushi_anki_settings', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(
        BaseAnkiRepository.defaultSettingsStore,
        isA<SharedPreferencesAnkiSettingsStore>(),
      );
      await _Repo().saveSettings(const AnkiSettings(selectedDeckName: 'Sp'));
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('fushi_anki_settings'),
        contains('"selectedDeckName":"Sp"'),
      );
      expect((await _Repo().loadSettings()).selectedDeckName, 'Sp');
    });

    test('SP 实现仍做 W2-7 旧键搬移（搬后删旧键）', () async {
      final String legacy = _settingsJson(deck: 'Hoshi');
      SharedPreferences.setMockInitialValues(<String, Object>{
        AnkiSettingsSharedPreferencesKeys.legacySettingsKey: legacy,
      });
      expect(await const SharedPreferencesAnkiSettingsStore().read(), legacy);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('fushi_anki_settings'), legacy);
      expect(
        prefs.getString(AnkiSettingsSharedPreferencesKeys.legacySettingsKey),
        isNull,
      );
    });
  });
}
