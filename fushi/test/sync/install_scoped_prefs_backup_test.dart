// 「本次安装」的一次性判定键（SyncRepository.installScopedPrefKeys，目前只有
// `srs_mining_target_install_default`）不得随备份 / 推荐包出境，导入时也不采信外来值。
//
// 事故形态：维护者用装了新版的机器打推荐包，包里带着 'anki'；新用户在引导里一导入，
// 推荐包把偏好整层换掉，标记 = 'anki' 又兼「已判定」，于是被永久当成老 Anki 用户
// （复习模块关、挖词发 Anki）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

const String _marker = PreferencesRepository.srsMiningTargetInstallDefaultKey;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_install_scoped_');
  });

  tearDown(() => cleanupTempDir(tmp));

  Future<Directory> dir(String name) =>
      Directory(p.join(tmp.path, name)).create(recursive: true);

  /// 一份「旧版本打出来的」包：真实的当前 schema 库，偏好里带着 [marker] 与推荐包
  /// 会带的设置（引导已完成等），未经导出剔除——模拟修复前导出的产物。
  Future<String> legacyPackCarrying(String marker) async {
    final Directory src = await dir('legacy_src');
    final FushiDatabase db = FushiDatabase(src.path);
    // 与 app 写入同一编码（PrefCodec），模拟真实的包。
    await db.setPrefTyped<String>(_marker, marker);
    await db.setPrefTyped<bool>('onboarding_completed', true);
    await db.setPrefTyped<int>('reader_font_size', 19);
    final int schemaVersion = db.schemaVersion;
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await db.close();
    final List<int> dbBytes = File(
      p.join(src.path, fushiDatabaseFileName),
    ).readAsBytesSync();
    final List<int> meta = utf8.encode(
      jsonEncode(
        BackupMeta(
          appVersion: '2.0.0',
          schemaVersion: schemaVersion,
          createdAt: DateTime(2026, 10, 16),
          bookCount: 0,
          statsCount: 0,
        ).toJson(),
      ),
    );
    final Archive archive = Archive()
      ..addFile(ArchiveFile(fushiDatabaseFileName, dbBytes.length, dbBytes))
      ..addFile(ArchiveFile('backup_meta.json', meta.length, meta));
    final String zipPath = p.join(tmp.path, 'legacy_pack_$marker.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive)!);
    return zipPath;
  }

  /// 本机：一个已跑过启动判定的安装（走真实的 settle）。返回 support 目录。
  Future<String> settledDevice({required bool existingUser}) async {
    final Directory support = await dir('device');
    final FushiDatabase db = FushiDatabase(support.path);
    final PreferencesRepository repo = PreferencesRepository(db);
    await repo.loadFromDb();
    if (existingUser) await repo.setPref('last_selected_deck', 'Mining');
    await repo.settleSrsMiningTargetInstallDefault();
    expect(repo.getPref(_marker), existingUser ? 'anki' : 'srs');
    repo.dispose();
    await db.close();
    return support.path;
  }

  /// 模拟导入后重启：重新装载偏好并跑启动判定，返回最终挖词目标。
  Future<SrsMiningTarget> restartAndRead(
    String support, {
    bool freshOnboardingPackImport = false,
  }) async {
    final FushiDatabase db = FushiDatabase(support);
    final PreferencesRepository repo = PreferencesRepository(db);
    try {
      await repo.loadFromDb();
      await repo.settleSrsMiningTargetInstallDefault(
        freshOnboardingPackImport: freshOnboardingPackImport,
      );
      return SrsMiningTarget.fromWire(repo.srsMiningTarget);
    } finally {
      repo.dispose();
      await db.close();
    }
  }

  test('判定键登记为设备本地：Profile / 备份 / 分享三条出境通道共用的谓词都认它', () {
    expect(SyncRepository.installScopedPrefKeys, contains(_marker));
    expect(SyncRepository.deviceLocalPrefKeys, contains(_marker));
    expect(PrefRedactionPolicy.isDeviceLocalOrCredential(_marker), isTrue);
    expect(ProfileKeys.isExcludedPref(_marker), isTrue);
  });

  group('导出', () {
    for (final ({String name, Set<BackupCategory>? categories}) c
        in <({String name, Set<BackupCategory>? categories})>[
          (name: '整份备份', categories: null),
          (
            name: '推荐包类目（词典 + 本地音频）',
            categories: <BackupCategory>{
              BackupCategory.dictionary,
              BackupCategory.localAudio,
            },
          ),
        ]) {
      test('${c.name}的导出产物里没有判定键（偏好表与 Profile 快照都没有）', () async {
        final Directory src = await dir('export_src');
        final FushiDatabase db = FushiDatabase(src.path);
        await db.setPrefTyped<String>(_marker, 'anki');
        await db.setPrefTyped<int>('reader_font_size', 19);
        // 修复前留下的 Profile 快照行（ProfileKeys 早就排除了，这里兜存量）。
        final int profileId = await db
            .into(db.profiles)
            .insert(
              ProfilesCompanion.insert(name: 'P', createdAt: 0, updatedAt: 0),
            );
        await db
            .into(db.profileSettings)
            .insert(
              ProfileSettingsCompanion.insert(
                profileId: profileId,
                category: ProfileKeys.categoryPref,
                key: _marker,
                value: 'anki',
              ),
            );
        final String zipPath = p.join(tmp.path, 'export.zip');
        await BackupService(
          db: db,
          dbDirectory: src.path,
          appVersion: '1.0.0',
        ).createBackup(zipPath, categories: c.categories);
        await db.close();

        // 直接解出包里的主库检查，不经导入侧（导入侧另有一道过滤，会掩盖导出泄漏）。
        final Directory unpacked = await dir('export_unpacked');
        final Archive archive = ZipDecoder().decodeBytes(
          File(zipPath).readAsBytesSync(),
        );
        final ArchiveFile entry = archive.files.firstWhere(
          (ArchiveFile f) => f.name == fushiDatabaseFileName,
        );
        File(
          p.join(unpacked.path, fushiDatabaseFileName),
        ).writeAsBytesSync(entry.content as List<int>);
        final FushiDatabase packed = FushiDatabase(unpacked.path);
        addTearDown(packed.close);
        expect(await packed.getPref(_marker), isNull);
        final List<QueryRow> snapshotRows = await packed
            .customSelect(
              'SELECT 1 FROM profile_settings WHERE key = ?',
              variables: <Variable<Object>>[Variable<String>(_marker)],
            )
            .get();
        expect(snapshotRows, isEmpty);
      });
    }
  });

  group('导入', () {
    test('新用户（已判定 srs）导入带 anki 的旧包 → 仍是 srs', () async {
      final String support = await settledDevice(existingUser: false);
      await BackupRestoreService.restoreBackup(
        dbDirectory: support,
        zipPath: await legacyPackCarrying('anki'),
      );
      final FushiDatabase db = FushiDatabase(support);
      expect(await db.getPrefTyped<String>(_marker, ''), 'srs');
      expect(
        await db.getPrefTyped<int>('reader_font_size', 0),
        19,
        reason: '其余设置照常随包恢复',
      );
      await db.close();
      expect(
        await restartAndRead(support, freshOnboardingPackImport: true),
        SrsMiningTarget.srs,
      );
    });

    test('老用户（已判定 anki）导入带 srs 的包 → 仍是 anki，不改写本机判定', () async {
      final String support = await settledDevice(existingUser: true);
      await BackupRestoreService.restoreBackup(
        dbDirectory: support,
        zipPath: await legacyPackCarrying('srs'),
      );
      final FushiDatabase db = FushiDatabase(support);
      expect(await db.getPrefTyped<String>(_marker, ''), 'anki');
      await db.close();
      expect(await restartAndRead(support), SrsMiningTarget.anki);
    });

    test('不导入设置（importSettings=false）也不改写本机判定', () async {
      final String support = await settledDevice(existingUser: false);
      await BackupRestoreService.restoreBackup(
        dbDirectory: support,
        zipPath: await legacyPackCarrying('anki'),
        importSettings: false,
      );
      final FushiDatabase db = FushiDatabase(support);
      expect(await db.getPrefTyped<String>(_marker, ''), 'srs');
      await db.close();
    });

    test('还没有活库的全新安装直接导入带 anki 的旧包 → 外来值被丢弃，启动判定得 srs', () async {
      final Directory support = await dir('fresh');
      await BackupRestoreService.restoreBackup(
        dbDirectory: support.path,
        zipPath: await legacyPackCarrying('anki'),
      );
      final FushiDatabase db = FushiDatabase(support.path);
      expect(await db.getPref(_marker), isNull, reason: '外来的判定结论不得采信');
      expect(
        await db.getPrefTyped<bool>('onboarding_completed', false),
        isTrue,
        reason: '其余设置照常随包恢复',
      );
      await db.close();
      // 引导里导入推荐包后重启：回执在，只认制卡数据信号 → 新用户。
      expect(
        await restartAndRead(support.path, freshOnboardingPackImport: true),
        SrsMiningTarget.srs,
      );
      final FushiDatabase after = FushiDatabase(support.path);
      addTearDown(after.close);
      expect(
        await after.getPref(ModuleId.srs.prefKey),
        isNull,
        reason: '新用户复习模块按出厂默认（开），不被写成关',
      );
    });
  });
}
