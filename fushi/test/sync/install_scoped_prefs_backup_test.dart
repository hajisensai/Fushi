// 「本次安装」的一次性判定键（SyncRepository.installScopedPrefKeys，目前只有
// `srs_mining_target_install_default`）不得随备份 / 推荐包出境；导入设置的恢复把它清掉
// （外来值、本机旧值都不留），下次启动按恢复后的数据重新判定。
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

  /// 一份备份 / 推荐包：真实的当前 schema 库，未经导出剔除（[marker] 非 null 时偏好里
  /// 带着判定键——模拟修复前导出的产物）。
  ///
  /// - [oldAnkiUser]：老 Anki 用户的完整备份——引导已完成、选过 Anki 牌组、有制卡历史。
  /// - 否则是推荐包形态：带着引导已完成等设置，但没有任何制卡数据。
  /// - [explicitTarget]：用户显式设过的 `srs_mining_target`（普通偏好，随设置恢复）。
  Future<String> backupZip({
    String? marker,
    bool oldAnkiUser = false,
    String? explicitTarget,
  }) async {
    final Directory src = await dir('backup_src');
    final FushiDatabase db = FushiDatabase(src.path);
    // 与 app 写入同一编码（PrefCodec），模拟真实的包。
    if (marker != null) await db.setPrefTyped<String>(_marker, marker);
    await db.setPrefTyped<bool>('onboarding_completed', true);
    await db.setPrefTyped<int>('reader_font_size', 19);
    if (oldAnkiUser) {
      await db.setPrefTyped<String>('last_selected_deck', 'Mining');
      await db.customStatement(
        'INSERT INTO mined_sentences (expression, source, date_key, created_at) '
        "VALUES ('猫', 'reader', '2026-01-01', 0)",
      );
    }
    if (explicitTarget != null) {
      await db.setPrefTyped<String>(
        PreferencesRepository.srsMiningTargetKey,
        explicitTarget,
      );
    }
    final int schemaVersion = db.schemaVersion;
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await db.close();
    final List<int> dbBytes = File(
      p.join(src.path, fushiDatabaseFileName),
    ).readAsBytesSync();
    await src.delete(recursive: true);
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
    final String zipPath = p.join(tmp.path, 'backup.zip');
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

  /// 模拟导入后重启：重新装载偏好并跑启动判定，返回最终挖词目标与复习模块开关。
  Future<({SrsMiningTarget target, bool srsModule, Object? marker})>
  restartAndRead(
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
      return (
        target: SrsMiningTarget.fromWire(repo.srsMiningTarget),
        srsModule: repo.moduleEnabled(ModuleId.srs),
        marker: repo.getPref(_marker),
      );
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
    /// 导入后、重启前直接读库里的判定键（PrefCodec 解码）。
    Future<String?> storedMarker(String support) async {
      final FushiDatabase db = FushiDatabase(support);
      try {
        final String value = await db.getPrefTyped<String>(_marker, '');
        return value.isEmpty ? null : value;
      } finally {
        await db.close();
      }
    }

    test('新装已判 srs，恢复老 Anki 用户的完整备份 → 重启重判为 anki，复习模块关', () async {
      final String support = await settledDevice(existingUser: false);
      await BackupRestoreService.restoreBackup(
        dbDirectory: support,
        zipPath: await backupZip(oldAnkiUser: true),
      );
      expect(
        await storedMarker(support),
        isNull,
        reason: '本机旧判定依据的是恢复前的数据，清掉重判',
      );
      final r = await restartAndRead(support);
      expect(r.target, SrsMiningTarget.anki);
      expect(r.srsModule, isFalse);
      expect(r.marker, 'anki');
    });

    test('新装已判 srs，引导里导入带 anki 判定值、无老用户数据的推荐包（有回执）→ 仍为 srs', () async {
      final String support = await settledDevice(existingUser: false);
      await BackupRestoreService.restoreBackup(
        dbDirectory: support,
        zipPath: await backupZip(marker: 'anki'),
      );
      expect(await storedMarker(support), isNull, reason: '外来的判定结论不得采信');
      final r = await restartAndRead(support, freshOnboardingPackImport: true);
      expect(r.target, SrsMiningTarget.srs);
      expect(r.srsModule, isTrue);
      expect(r.marker, 'srs');
    });

    test('新装已判 srs，恢复显式设了 srs_mining_target=srs 的老用户备份 → 仍为 srs', () async {
      final String support = await settledDevice(existingUser: false);
      await BackupRestoreService.restoreBackup(
        dbDirectory: support,
        zipPath: await backupZip(oldAnkiUser: true, explicitTarget: 'srs'),
      );
      final r = await restartAndRead(support);
      expect(r.marker, 'anki', reason: '出厂默认按恢复后的数据重判成老用户');
      expect(r.target, SrsMiningTarget.srs, reason: '显式选过的挖词目标随设置恢复，重判不覆盖');
      expect(r.srsModule, isTrue, reason: '显式在用 Fushi 复习：模块没设过就按开处理');
    });

    test('反向：恢复显式设了 srs_mining_target=anki 的老用户备份 → anki，复习模块关', () async {
      final String support = await settledDevice(existingUser: false);
      await BackupRestoreService.restoreBackup(
        dbDirectory: support,
        zipPath: await backupZip(oldAnkiUser: true, explicitTarget: 'anki'),
      );
      final r = await restartAndRead(support);
      expect(r.marker, 'anki');
      expect(r.target, SrsMiningTarget.anki);
      expect(r.srsModule, isFalse);
    });

    test('不导入设置（importSettings=false）时本机判定不变', () async {
      final String support = await settledDevice(existingUser: false);
      await BackupRestoreService.restoreBackup(
        dbDirectory: support,
        zipPath: await backupZip(marker: 'anki', oldAnkiUser: true),
        importSettings: false,
      );
      expect(await storedMarker(support), 'srs');
      final r = await restartAndRead(support);
      expect(r.target, SrsMiningTarget.srs);
      expect(r.srsModule, isTrue);
    });

    test('还没有活库的全新安装直接导入带 anki 的旧推荐包 → 外来值被丢弃，启动判定得 srs', () async {
      final Directory support = await dir('fresh');
      await BackupRestoreService.restoreBackup(
        dbDirectory: support.path,
        zipPath: await backupZip(marker: 'anki'),
      );
      expect(await storedMarker(support.path), isNull, reason: '外来的判定结论不得采信');
      final r = await restartAndRead(
        support.path,
        freshOnboardingPackImport: true,
      );
      expect(r.target, SrsMiningTarget.srs);
      expect(r.srsModule, isTrue);
    });

    test('崩溃恢复重放导入设置的恢复：本机旧值与外来值同样清掉', () async {
      final Directory support = await dir('crashed');
      // 中途崩溃的导入：活库已是备份的（带外来判定 'anki'），sidecar 记着本机的 'srs'。
      final FushiDatabase db = FushiDatabase(support.path);
      await db.setPrefTyped<String>(_marker, 'anki');
      await db.close();
      await File(
        p.join(support.path, '$fushiDatabaseFileName.sync-preserve.json'),
      ).writeAsString(
        jsonEncode(<String, dynamic>{
          'mode': 'prefs',
          'prefs': <String, String>{_marker: PrefCodec.encode('srs')},
        }),
      );
      await BackupRestoreService.recoverPendingRestore(support.path);
      expect(await storedMarker(support.path), isNull);
    });
  });
}
